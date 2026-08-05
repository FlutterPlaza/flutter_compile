import org.jetbrains.intellij.platform.gradle.IntelliJPlatformType
import org.jetbrains.intellij.platform.gradle.models.ProductRelease

plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.2.20"
    id("org.jetbrains.intellij.platform") version "2.18.1"
}

group = "com.flutterplaza.fluttercompile"
version = "0.3.6"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    intellijPlatform {
        intellijIdeaCommunity("2025.1")
        bundledPlugin("com.intellij.modules.platform")
        bundledPlugin("org.jetbrains.plugins.terminal")
        plugin("Dart", "251.27623.5")
        plugin("io.flutter", "89.0.0")
        pluginVerifier()
    }
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "251"
            // No upper bound: stay installable on future IDE releases without
            // a re-release (per JetBrains guidance on until-build).
            untilBuild = provider { null }
        }
    }
    buildSearchableOptions = false

    pluginVerification {
        ides {
            // Every stable Android Studio release line the declared range
            // covers, resolved from the official releases feed.
            select {
                types = listOf(IntelliJPlatformType.AndroidStudio)
                channels = listOf(ProductRelease.Channel.RELEASE)
                sinceBuild = "251"
            }
        }
    }

    signing {
        certificateChain = providers.environmentVariable("CERTIFICATE_CHAIN")
        privateKey = providers.environmentVariable("PRIVATE_KEY")
        password = providers.environmentVariable("PRIVATE_KEY_PASSWORD")
    }

    publishing {
        token = providers.environmentVariable("PUBLISH_TOKEN")
    }
}

// Mirror the plugin-verification criteria so `./gradlew printProductsReleases`
// lists the Android Studio releases `verifyPlugin` runs against.
tasks.named<org.jetbrains.intellij.platform.gradle.tasks.PrintProductsReleasesTask>("printProductsReleases") {
    types = listOf(IntelliJPlatformType.AndroidStudio)
    channels = listOf(ProductRelease.Channel.RELEASE)
    sinceBuild = "251"
}
