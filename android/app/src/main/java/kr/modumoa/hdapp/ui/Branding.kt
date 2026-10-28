package kr.modumoa.hdapp.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.RenderVectorGroup
import androidx.compose.ui.graphics.vector.VectorConfig
import androidx.compose.ui.graphics.vector.VectorProperty
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.unit.dp
import kr.modumoa.hdapp.R
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

@Composable
fun LoginBranding() {
    var introPlayed by rememberSaveable { mutableStateOf(false) }
    var settled by remember { mutableStateOf(introPlayed) }
    val rays = remember { Animatable(if (introPlayed) 1f else 0f) }
    val bloom = remember { Animatable(if (introPlayed) 1f else 0f) }
    val wordmark = remember { Animatable(if (introPlayed) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!introPlayed) {
            // 시작 시 저장하므로 등장 도중 회전해도 다시 재생하지 않는다.
            introPlayed = true
            coroutineScope {
                launch { rays.animateTo(1f, motionTween(MotionBrand)) }
                launch { bloom.animateTo(1f, motionTween(MotionBrand, MotionBloomDelay)) }
                launch { wordmark.animateTo(1f, motionTween(MotionNormal, MotionWordmarkDelay)) }
            }
            settled = true
        }
    }

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(CarGap)) {
        val cockpit = if (settled) painterResource(R.drawable.brand_cockpit_horizon) else {
            val vector = ImageVector.vectorResource(R.drawable.brand_cockpit_horizon)
            val configs = remember(rays.value, bloom.value) {
                buildMap<String, VectorConfig> {
                    val rayConfig = BrandVectorConfig(alpha = rays.value)
                    repeat(8) { put("sunburst_ray_${it + 1}", rayConfig) }
                    // 원본 꽃 중심에서 0.7→1로 등장하며 원본 경로·색·구도는 유지한다.
                    put("voice_bloom_motion", BrandVectorConfig(scale = 0.7f + 0.3f * bloom.value))
                    val bloomConfig = BrandVectorConfig(alpha = if (bloom.value == 0f) 0f else 1f)
                    repeat(8) { put("voice_bloom_path_${it + 1}", bloomConfig) }
                }
            }
            rememberVectorPainter(
                defaultWidth = vector.defaultWidth, defaultHeight = vector.defaultHeight,
                viewportWidth = vector.viewportWidth, viewportHeight = vector.viewportHeight,
                autoMirror = false,
            ) { _, _ -> RenderVectorGroup(vector.root, configs) }
        }
        Image(cockpit, contentDescription = null,
            modifier = Modifier.fillMaxWidth().height(260.dp), contentScale = ContentScale.Fit)
        Image(painterResource(R.drawable.brand_wordmark), contentDescription = "모두모아",
            modifier = Modifier.fillMaxWidth().height(64.dp).graphicsLayer { alpha = wordmark.value },
            contentScale = ContentScale.Fit, alignment = Alignment.CenterStart)
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
            // 보조 엠블럼 사방 40dp를 예약하고 주 워드마크와 별도 행에 둔다.
            Row(Modifier.padding(40.dp), horizontalArrangement = Arrangement.spacedBy(40.dp),
                verticalAlignment = Alignment.CenterVertically) {
                // 공식 현대자동차 엠블럼 파일로 교체 예정(변형 금지)
                Image(painterResource(R.drawable.hyundai_emblem), contentDescription = null,
                    modifier = Modifier.size(width = 160.dp, height = 80.dp), contentScale = ContentScale.Fit)
                Text("for Pleos", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

private class BrandVectorConfig(private val alpha: Float? = null, private val scale: Float? = null) : VectorConfig {
    @Suppress("UNCHECKED_CAST")
    override fun <T> getOrDefault(property: VectorProperty<T>, defaultValue: T): T {
        // 여기서 재정의하는 네 속성은 모두 Float이므로 다른 벡터 속성은 원본으로 돌려준다.
        val value = when (property) {
            VectorProperty.FillAlpha, VectorProperty.StrokeAlpha -> alpha
            VectorProperty.ScaleX, VectorProperty.ScaleY -> scale
            else -> null
        }
        return if (value == null) defaultValue else value as T
    }
}
