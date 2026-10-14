plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.dshremote.dsh_remote_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.dshremote.dsh_remote_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // D-056: `local_auth` 的 Android 实现（BiometricPrompt）要求 API 24，
        // Flutter 默认的 21 装不上这个依赖。24 覆盖到 Android 7.0，已低于
        // 绝大多数在用机型，抬它换来屏 H 真的能校验而不是占位。
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // D-114：发布签名。此前 release 借用 debug 签名——那把钥匙是本机的
    // ~/.android/debug.keystore，换机器就丢；用它出公开渠道的包，等于发布
    // 物没有稳定的签名身份。
    //
    // 密钥**不在仓库里**（android/.gitignore 挡了 *.jks/*.keystore），也不写
    // 在这里——build.gradle 只从环境变量读路径与口令：
    //   DSH_RELEASE_KEYSTORE / DSH_RELEASE_STORE_PASSWORD / DSH_RELEASE_KEY_PASSWORD
    // 没配就**构建失败并说清怎么办**，而不是悄悄退回 debug 签名。
    signingConfigs {
        create("release") {
            val keystorePath = System.getenv("DSH_RELEASE_KEYSTORE")
            if (keystorePath.isNullOrBlank()) {
                throw GradleException(
                    "DSH_RELEASE_KEYSTORE is not set — release signing key is required. " +
                    "See scripts/build-release.sh; the key must live OUTSIDE the repo " +
                    "(e.g. ~/.config/dsh-remote/signing/). Refusing to sign a " +
                    "public release build with the debug key."
                )
            }
            storeFile = file(keystorePath)
            storePassword = System.getenv("DSH_RELEASE_STORE_PASSWORD")
            keyAlias = System.getenv("DSH_RELEASE_KEY_ALIAS") ?: "dsh-remote"
            keyPassword = System.getenv("DSH_RELEASE_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            // D-113：release 也走 FLAG_SECURE / allowBackup=false（main manifest
            // 里已声明，无需在 buildType 重复）。
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

// D-114：把 dev 依赖的 Android 插件从 release 的 registrant 里剔掉。
//
// 症状：`flutter build apk --release` 编译失败于
//   package dev.flutter.plugins.integration_test does not exist
//   （GeneratedPluginRegistrant.java 里 new IntegrationTestPlugin()）
//
// 成因：`integration_test` 在 dev_dependencies（D-080 真机 E2E 要用），而
// `.flutter-plugins-dependencies` 里它是 `native_build: true` + `dev_dependency:
// true`；这个 Flutter 版本的 registrant 生成器不按后者过滤，于是把一个**只该
// 出现在测试包里**的插件写进了 main 源集。官方没有开关（试过 build apk 的全部
// 选项，没有 --no-dev）。
//
// 为什么不能简单删掉那个文件：registrant 还要注册 flutter_secure_storage /
// url_launcher 这些真插件，删了等于 release 包运行时插件全不注册。
//
// 所以在编译任务**执行前**按 `.flutter-plugins-dependencies` 的真实 dev 标记
// 剔除对应行——不硬编码插件名，换依赖也不会失效。
val devDependencyPlugins: Set<String> = runCatching {
    val marker = file("../../.flutter-plugins-dependencies")
    if (!marker.exists()) {
        emptySet()
    } else {
        @Suppress("UNCHECKED_CAST")
        val parsed = groovy.json.JsonSlurper().parse(marker) as Map<String, Any>
        val android = ((parsed["plugins"] as? Map<String, Any>)?.get("android") as? List<*>)
            ?: emptyList<Any>()
        android
            .filterIsInstance<Map<*, *>>()
            .filter { it["dev_dependency"] == true }
            .mapNotNull { it["name"] as? String }
            .toSet()
    }
}.getOrElse { emptySet() }

fun File.stripDevPluginRegistrants(devPlugins: Set<String>) {
    if (!exists() || devPlugins.isEmpty()) return
    val text = readText()
    if (!devPlugins.any { text.contains("plugins.${it.replace('.', '_')}") ||
            text.contains("plugins/$it") }) return
    var changed = false
    val out = text.lineSequence().filter { line ->
        val hit = devPlugins.any { d ->
            line.contains("plugins.${d.replace('.', '_')}") || line.contains("plugins/$d")
        }
        if (hit) changed = true
        !hit
    }.toList()
    if (changed) {
        writeText(out.joinToString("\n"))
        logger.lifecycle("[release] stripped dev-dependency plugin(s) from GeneratedPluginRegistrant: $devPlugins")
    }
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("JavaWithJavac") }
    .configureEach {
        doFirst {
            file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
                .stripDevPluginRegistrants(devDependencyPlugins)
        }
    }
