pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        // D-056 落地时发现：Maven Central 从本机直连返回 403（代理 7897 也不通），
        // 而 `local_auth_android` 硬编码要 kotlin-gradle-plugin 2.3.20，缓存里没有，
        // 于是 Gradle 解析失败、APK 打不出来。阿里云镜像可以拿到。
        //
        // 位置是刻意的：放在 google() 之后、mavenCentral() **之前**——先试镜像，
        // 官方源仍留在后面做兜底，镜像挂了会自动回退，不会把构建锁死在镜像上。
        // 任何人 clone 下来都受益，不是我这台机器的私有配置。
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
