package kr.modumoa.hdapp.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kr.modumoa.hdapp.R

private val LocalWordmarkOpacity = staticCompositionLocalOf<() -> Float> { { 1f } }

@Composable
internal fun ModumoaBranding(content: @Composable () -> Unit) {
    var introPlayed by rememberSaveable { mutableStateOf(false) }
    val opacity = remember { Animatable(if (introPlayed) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!introPlayed) {
            introPlayed = true
            opacity.animateTo(1f, motionTween(MotionBrand))
        }
    }
    // 로그인·로그아웃이나 경로 이동으로 워드마크가 재구성되어도 재생은 루트에서 한 번만 한다.
    val alpha = remember { { opacity.value } }
    CompositionLocalProvider(LocalWordmarkOpacity provides alpha, content = content)
}

@Composable
fun ModumoaWordmark() {
    val opacity = LocalWordmarkOpacity.current
    val appName = stringResource(R.string.app_name)
    Row(Modifier.graphicsLayer { alpha = opacity() }.clearAndSetSemantics { contentDescription = appName },
        horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("우나보", fontFamily = BlackHanSans, fontSize = 44.sp, lineHeight = 44.sp,
            color = MaterialTheme.colorScheme.onSurface)
        Text("UNAVO", fontFamily = Rye, fontSize = 20.sp, lineHeight = 22.sp,
            color = LocalModumoaColors.current.accent)
    }
}

@Composable
fun LoginBranding(modifier: Modifier = Modifier, verticalClearspace: Dp = 40.dp) {
    BoxWithConstraints(modifier) {
        val emblem: @Composable () -> Unit = {
            // 가로 보호 영역은 항상 40dp. 한 줄 배치에서는 부모가 세로 보호 영역을 확보한다.
            Image(painterResource(R.drawable.hyundai_emblem), contentDescription = null,
                modifier = Modifier.padding(horizontal = 40.dp, vertical = verticalClearspace)
                    .size(width = 160.dp, height = 80.dp),
                contentScale = ContentScale.Fit)
        }
        if (maxWidth >= 380.dp) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                emblem()
                Text("for Pleos", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            Column {
                emblem()
                Text("for Pleos", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
