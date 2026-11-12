import java.io.FileInputStream
import java.io.InputStreamReader
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
val keystoreProperties = Properties()
if (hasReleaseSigning) {
    InputStreamReader(FileInputStream(keystorePropertiesFile), Charsets.UTF_8).use {
        keystoreProperties.load(it)
    }
    for (key in listOf("storeFile", "storePassword", "keyAlias", "keyPassword")) {
        if (keystoreProperties.getProperty(key).isNullOrBlank()) {
            error("release 서명 설정에서 누락되었거나 비어 있는 키: $key")
        }
    }
}

android {
    namespace = "kr.modumoa.hdapp"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "kr.modumoa.hdapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = 34
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // key.properties가 있으면 검증한 release 키로, 없으면 개발용 debug 키로 서명한다.
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "release" else "debug")
        }
    }

    // 결정 17-(b): 제출 APK 는 arm64-v8a + x86_64 만. 32비트 플러그인 라이브러리(약 27 MB)는 제외.
    packaging {
        jniLibs {
            excludes += setOf("lib/armeabi-v7a/**")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 기존 Kotlin 마이크 라우터/서비스에 이미 사용하던 네이티브 의존성.
dependencies {
    compileOnly(files("${android.sdkDirectory}/platforms/android-37.0/optional/android.car.jar"))
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
