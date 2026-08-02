package com.linkos.features.remotedesktop

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntSize

/**
 * Maps local Android touch surface coordinates to remote macOS display resolution.
 */
object TouchInputMapper {

    data class MappedCoordinate(
        val macX: Double,
        val macY: Double,
        val isOutOfBounds: Boolean
    )

    fun mapTouchToMac(
        touchOffset: Offset,
        containerSize: IntSize,
        macDisplayWidth: Int = 3024,
        macDisplayHeight: Int = 1964
    ): MappedCoordinate {
        if (containerSize.width == 0 || containerSize.height == 0) {
            return MappedCoordinate(0.0, 0.0, true)
        }

        val normX = (touchOffset.x / containerSize.width.toDouble()).coerceIn(0.0, 1.0)
        val normY = (touchOffset.y / containerSize.height.toDouble()).coerceIn(0.0, 1.0)

        val macX = normX * macDisplayWidth
        val macY = normY * macDisplayHeight

        val outOfBounds = touchOffset.x < 0 || touchOffset.x > containerSize.width ||
                touchOffset.y < 0 || touchOffset.y > containerSize.height

        return MappedCoordinate(
            macX = macX,
            macY = macY,
            isOutOfBounds = outOfBounds
        )
    }
}
