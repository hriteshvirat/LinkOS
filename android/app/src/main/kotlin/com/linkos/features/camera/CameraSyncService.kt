package com.linkos.features.camera

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import androidx.camera.core.CameraControl
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.qualifiers.ApplicationContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class CameraSyncService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val connectionStateManager: ConnectionStateManager,
    private val webSocketClient: WebSocketClient
) {
    private var cameraProvider: ProcessCameraProvider? = null
    private var cameraControl: CameraControl? = null
    private var isStreaming = false
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var isFlashEnabled = false
    private var zoomRatio = 1.0f
    private var onNextFrameCaptured: ((Bitmap) -> Unit)? = null
    
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var activeCameraSessionId: String? = null
    private var frameCount = 0
    
    fun startCameraStream(lifecycleOwner: LifecycleOwner, previewView: PreviewView? = null) {
        if (isStreaming) return
        activeCameraSessionId = java.util.UUID.randomUUID().toString().substring(0, 8)
        frameCount = 0
        
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()
            bindCameraUseCases(lifecycleOwner, previewView)
        }, ContextCompat.getMainExecutor(context))
    }

    private fun bindCameraUseCases(lifecycleOwner: LifecycleOwner, previewView: PreviewView? = null) {
        val provider = cameraProvider ?: return
        
        val cameraSelector = CameraSelector.Builder()
            .requireLensFacing(lensFacing)
            .build()
            
        val imageAnalysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .build()
            
        imageAnalysis.setAnalyzer(cameraExecutor) { imageProxy ->
            if (isStreaming) {
                processImageFrame(imageProxy)
            } else {
                imageProxy.close()
            }
        }
        
        val useCases = mutableListOf<androidx.camera.core.UseCase>(imageAnalysis)
        if (previewView != null) {
            val preview = Preview.Builder().build()
            preview.setSurfaceProvider(previewView.surfaceProvider)
            useCases.add(preview)
        }
        
        try {
            provider.unbindAll()
            val camera = provider.bindToLifecycle(
                lifecycleOwner,
                cameraSelector,
                *useCases.toTypedArray()
            )
            cameraControl = camera.cameraControl
            cameraControl?.setZoomRatio(zoomRatio)
            cameraControl?.enableTorch(isFlashEnabled)
            isStreaming = true
            LinkOSLogger.info("[CameraContinuity] [${System.currentTimeMillis()}] [${activeCameraSessionId}] Stage: Opened - Camera stream bound successfully", "CameraSync")
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to bind camera use cases: ${e.message}", "CameraSync")
        }
    }

    fun stopCameraStream() {
        if (!isStreaming) return
        isStreaming = false
        cameraProvider?.unbindAll()
        cameraControl = null
        LinkOSLogger.info("[CameraContinuity] [${System.currentTimeMillis()}] [${activeCameraSessionId}] Stage: Closed - Camera streaming stopped", "CameraSync")
        activeCameraSessionId = null
    }

    fun switchCamera(lifecycleOwner: LifecycleOwner, previewView: PreviewView? = null) {
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        if (isStreaming) {
            stopCameraStream()
            startCameraStream(lifecycleOwner, previewView)
        }
    }

    fun toggleFlash(enabled: Boolean) {
        isFlashEnabled = enabled
        cameraControl?.enableTorch(enabled)
        LinkOSLogger.info("Camera torch set to: $enabled", "CameraSync")
    }

    fun setZoom(zoom: Float) {
        zoomRatio = zoom.coerceIn(1.0f, 5.0f)
        cameraControl?.setZoomRatio(zoomRatio)
        LinkOSLogger.info("Camera zoom ratio set to: $zoomRatio", "CameraSync")
    }

    private fun imageProxyToBitmap(image: ImageProxy): Bitmap {
        val bitmap = Bitmap.createBitmap(
            image.width,
            image.height,
            Bitmap.Config.ARGB_8888
        )
        val buffer = image.planes[0].buffer
        buffer.rewind() // Ensure buffer position is reset
        bitmap.copyPixelsFromBuffer(buffer)
        
        val rotationDegrees = image.imageInfo.rotationDegrees
        if (rotationDegrees != 0) {
            val matrix = android.graphics.Matrix().apply {
                postRotate(rotationDegrees.toFloat())
            }
            return Bitmap.createBitmap(
                bitmap,
                0,
                0,
                bitmap.width,
                bitmap.height,
                matrix,
                true
            )
        }
        return bitmap
    }

    @androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
    private fun processImageFrame(imageProxy: ImageProxy) {
        val sessionId = activeCameraSessionId ?: "unknown"
        frameCount++
        val shouldLog = frameCount % 30 == 1
        
        if (shouldLog) {
            LinkOSLogger.info("[CameraContinuity] [${System.currentTimeMillis()}] [${sessionId}] Stage: Captured - Frame captured width=${imageProxy.width}, height=${imageProxy.height}", "CameraSync")
        }

        try {
            val bitmap = imageProxyToBitmap(imageProxy)
            onNextFrameCaptured?.let { callback ->
                onNextFrameCaptured = null
                callback(bitmap)
            }
            imageProxy.close()
            
            val encodeStart = System.currentTimeMillis()
            // Downscale frame to keep bandwidth utilization optimal
            val resized = Bitmap.createScaledBitmap(bitmap, 480, 360, true)
            
            val outputStream = ByteArrayOutputStream()
            resized.compress(Bitmap.CompressFormat.JPEG, 70, outputStream)
            val jpegBytes = outputStream.toByteArray()
            val base64Data = Base64.encodeToString(jpegBytes, Base64.NO_WRAP)
            val encodeDuration = System.currentTimeMillis() - encodeStart
            
            if (shouldLog) {
                LinkOSLogger.info("[CameraContinuity] [${System.currentTimeMillis()}] [${sessionId}] Stage: Encoded - Frame compressed to JPEG size=${jpegBytes.size} bytes in ${encodeDuration}ms", "CameraSync")
            }
            
            val payload: JSONObject = JSONObject().apply {
                put("timestamp_ms", System.currentTimeMillis())
                put("flash_active", isFlashEnabled)
                put("lens_facing", if (lensFacing == CameraSelector.LENS_FACING_BACK) "rear" else "front")
                put("image", base64Data)
            }
            
            webSocketClient.sendEnvelope("camera", payload.toString(), type = "event")
            if (shouldLog) {
                LinkOSLogger.info("[CameraContinuity] [${System.currentTimeMillis()}] [${sessionId}] Stage: Transmitted - Frame socket envelope dispatched", "CameraSync")
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to process image frame: ${e.message}", "CameraSync")
            imageProxy.close()
        }
    }

    fun sendControlMessage(payload: String) {
        webSocketClient.sendEnvelope("camera", payload, type = "event")
    }

    fun capturePhoto(callback: (Bitmap) -> Unit) {
        onNextFrameCaptured = callback
    }
}
