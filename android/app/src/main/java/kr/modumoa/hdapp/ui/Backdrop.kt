package kr.modumoa.hdapp.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kr.modumoa.hdapp.R

@Immutable
internal data class WesternFrame(val width: Dp = 1682.dp, val height: Dp = 1210.dp) {
    val compact get() = width < 1000.dp || height < 800.dp
    val margin get() = if (width < 600.dp) 16.dp else 56.dp
}
internal val LocalWesternFrame = staticCompositionLocalOf { WesternFrame() }

@Composable
fun ModumoaBackdrop(content: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // 포스터는 로그인·모든 경로가 공유하는 루트에서 한 번만 그린다.
        Image(
            painterResource(if (LocalModumoaDarkTheme.current) R.drawable.unavo_western_night else R.drawable.unavo_western_day),
            contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop,
        )
        ModumoaBranding {
            CompositionLocalProvider(
                LocalWesternFrame provides WesternFrame(maxWidth, maxHeight),
                LocalContentColor provides MaterialTheme.colorScheme.onSurface,
                content = content,
            )
        }
    }
}

@Composable
fun WesternHeader(actions: @Composable RowScope.() -> Unit) {
    val frame = LocalWesternFrame.current
    val modifier = Modifier.fillMaxWidth().padding(horizontal = frame.margin)
        .padding(top = if (frame.compact) 16.dp else 32.dp)
    val account: @Composable () -> Unit = {
        Surface(shape = MaterialTheme.shapes.extraLarge, color = LocalModumoaColors.current.panel,
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)) {
            Row(Modifier.padding(horizontal = if (frame.compact) 12.dp else 24.dp, vertical = if (frame.compact) 12.dp else 8.dp),
                horizontalArrangement = Arrangement.spacedBy(CarGap),
                verticalAlignment = Alignment.CenterVertically, content = actions)
        }
    }
    if (frame.width < 700.dp) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ModumoaWordmark()
            account()
        }
    } else {
        Row(modifier.heightIn(min = 128.dp), horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Top) {
            ModumoaWordmark()
            account()
        }
    }
}

@Composable
fun WesternFooter(navigation: (@Composable RowScope.() -> Unit)? = null) {
    val frame = LocalWesternFrame.current
    Row(Modifier.fillMaxWidth().padding(horizontal = frame.margin)
        .padding(top = 8.dp, bottom = if (frame.compact) 16.dp else 32.dp)
        .heightIn(min = 104.dp), horizontalArrangement = Arrangement.spacedBy(CarGap),
        verticalAlignment = Alignment.CenterVertically) {
        if (frame.width >= 1000.dp) {
            Text("같이 길을 개척한다.", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
        } else if (frame.width >= 600.dp) Spacer(Modifier.weight(1f))
        if (navigation != null) {
            Surface(shape = MaterialTheme.shapes.extraLarge, color = LocalModumoaColors.current.panel,
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)) {
                Row(Modifier.padding(horizontal = when {
                    frame.width < 360.dp -> 0.dp
                    frame.width < 600.dp -> 12.dp
                    else -> 20.dp
                }, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(CarGap), verticalAlignment = Alignment.CenterVertically) {
                    if (frame.width >= 600.dp) Text("우나보", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    navigation()
                }
            }
        }
    }
}

@Composable
fun WesternScreen(referenceHeight: Dp = 400.dp, content: @Composable ColumnScope.() -> Unit) {
    val frame = LocalWesternFrame.current
    BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = frame.margin)) {
        // 모든 화면은 기본 400dp 패널을 사용해 1210dp에서 레터링 아래 Y=666을 유지한다.
        val panelHeight = (frame.height * (referenceHeight.value / 1210f)).coerceAtLeast(referenceHeight)
            .coerceAtMost(maxHeight)
        Column(Modifier.fillMaxSize()) {
            if (!frame.compact && this@BoxWithConstraints.maxHeight > panelHeight) Spacer(Modifier.weight(1f))
            Surface(
                modifier = if (frame.compact) Modifier.fillMaxWidth().weight(1f)
                    else Modifier.fillMaxWidth().heightIn(min = panelHeight, max = panelHeight),
                shape = MaterialTheme.shapes.extraLarge,
                color = LocalModumoaColors.current.panel,
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
            ) {
                Column(Modifier.fillMaxSize().padding(
                    horizontal = if (frame.width < 600.dp) 16.dp else 40.dp, vertical = 30.dp,
                ), content = content)
            }
        }
    }
}

@Composable
fun WesternColumns(
    left: LazyListScope.() -> Unit,
    right: LazyListScope.() -> Unit,
    modifier: Modifier = Modifier,
    leftWeight: Float = 0.4f,
    header: @Composable () -> Unit = {},
    rightContentPadding: PaddingValues = PaddingValues(vertical = 9.dp),
) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        if (maxWidth >= 900.dp) {
            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(15.dp)) {
                header()
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(56.dp)) {
                    LazyColumn(Modifier.weight(leftWeight).fillMaxHeight(),
                        contentPadding = PaddingValues(vertical = 9.dp),
                        verticalArrangement = Arrangement.spacedBy(CarGap), content = left)
                    LazyColumn(Modifier.weight(1f - leftWeight).fillMaxHeight(),
                        contentPadding = rightContentPadding,
                        verticalArrangement = Arrangement.spacedBy(CarGap), content = right)
                }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = rightContentPadding,
                verticalArrangement = Arrangement.spacedBy(CarGap)) {
                item { header() }
                left()
                right()
            }
        }
    }
}

@Composable
fun WesternPanelTitle(title: String, trailing: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CarGap),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.headlineMedium,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        trailing()
    }
}
