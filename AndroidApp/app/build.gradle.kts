import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.ralphgeb.halo"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.ralphgeb.halo"
        // Health Connect needs Android 9 or later (it's built in from Android 14)
        minSdk = 28
        targetSdk = 35
        // CI sets the build number from the run number
        versionCode = (System.getenv("HALO_BUILD_NUMBER") ?: "1").toInt()
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // signed in CI when the upload key is set; otherwise left unsigned
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { compose = true }

    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":core"))

    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Home-screen widget
    implementation("androidx.glance:glance-appwidget:1.1.1")

    // Health Connect: where the Fitbit app (and others) keep sleep, heart rate, steps and more
    implementation("androidx.health.connect:connect-client:1.1.0-alpha10")
}
