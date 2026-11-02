package app.bighelp.android

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// The same first-party brand path as BighelpNoodleShape on Apple platforms.
private val noodlePath = Path().apply {
    val k = 13.807f
    moveTo(28f, 12f)
    lineTo(28f, 60f)
    cubicTo(28f, 60f + k, 53f - k, 85f, 53f, 85f)
    cubicTo(53f + k, 85f, 78f, 60f + k, 78f, 60f)
    cubicTo(78f, 60f - k, 53f + k, 35f, 53f, 35f)
    cubicTo(53f - k, 35f, 28f, 60f - k, 28f, 60f)
    cubicTo(28f, 80f, 22f, 90f, 8f, 94f)
}

@Composable
fun NoodleMark(modifier: Modifier = Modifier, height: Dp = 36.dp) {
    Canvas(modifier.width(height * (86f / 98f)).height(height)) {
        val unit = size.height / 98f
        translate(top = -4f * unit) {
            scale(scaleX = unit, scaleY = unit, pivot = androidx.compose.ui.geometry.Offset.Zero) {
                drawPath(noodlePath, Ember, style = Stroke(16f, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
        }
    }
}
