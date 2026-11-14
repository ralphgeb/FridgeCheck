pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Halo"

// The scores, models and sample data: plain Kotlin, the same maths as the iPhone app.
include(":core")
// The Android app (Jetpack Compose, Health Connect).
include(":app")
