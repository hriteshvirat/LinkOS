package com.linkos.features.phone

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream

/**
 * Decoupled screen streaming encoder interface to support different formats.
 */
interface FrameEncoder {
    fun encode(bitmap: Bitmap): ByteArray?
    fun setQuality(quality: Int)
}

/**
 * Implementation of FrameEncoder for compressing bitmaps to JPEG.
 */
class JPEGFrameEncoder(private var quality: Int = 80) : FrameEncoder {
    override fun encode(bitmap: Bitmap): ByteArray? {
        return try {
            val bos = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, bos)
            bos.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    override fun setQuality(quality: Int) {
        this.quality = quality.coerceIn(0, 100)
    }
}
