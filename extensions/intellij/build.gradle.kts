plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.1.0"
    id("org.jetbrains.intellij") version "1.17.2"
}

group = "com.flutterplaza.fluttercompile"
version = "0.1.0"

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(17)
}

intellij {
    version.set("2025.1")
    type.set("IC") // IntelliJ Community — also works with Android Studio
    plugins.set(listOf("Dart:251.27623.5", "io.flutter:89.0.0"))
}

tasks {
    patchPluginXml {
        sinceBuild.set("251")
        untilBuild.set("253.*")
    }

    buildSearchableOptions {
        enabled = false
    }
}
