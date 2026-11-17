plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
}

android {
    namespace = "app.floor.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "app.floor.android"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        // Phase 1 of the Android app; the release that ships it sets this from VERSION.
        versionName = "0.1.0"
        // The deployed API, as the iOS Release build reads it from FloorAPIBaseURL.
        buildConfigField("String", "API_BASE_URL", "\"https://floor-api.vercel.app\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests {
            // Robolectric draws the screenshot tests with the app's real fonts and resources.
            isIncludeAndroidResources = true
            all { test ->
                // One source of truth for both apps: the decode tests read the recorded API
                // responses the iOS tests use, from where they already live.
                test.systemProperty(
                    "floor.fixtures",
                    rootProject.file("../ios/FloorKit/Tests/ModelsTests/Fixtures").absolutePath,
                )
                // Cards print the day a vote happened in the reader's zone; Congress's is Eastern,
                // which is what the iOS references were drawn in too.
                test.systemProperty("user.timezone", "America/New_York")
                test.systemProperty("robolectric.graphicsMode", "NATIVE")
                // Robolectric's SDK 36 sandbox reaches into FileDescriptor through
                // jdk.internal.access, which JDK 17+ closes off; without these every screenshot
                // test dies in setup with "Failed to interact with raw FileDescriptor internals".
                test.jvmArgs(
                    "--add-opens=java.base/java.io=ALL-UNNAMED",
                    "--add-exports=java.base/jdk.internal.access=ALL-UNNAMED",
                )
            }
        }
    }

    lint {
        // Errors fail CI. Warnings are reported, except "a newer version exists": pins wait two
        // weeks after a release on purpose (libs.versions.toml), so that one is always true.
        abortOnError = true
        warningsAsErrors = false
        disable += setOf("NewerVersionAvailable", "AndroidGradlePluginVersion", "GradleDependency")
    }
}

roborazzi {
    // Committed references; `verifyRoborazziDebug` compares against them in CI.
    outputDir.set(file("src/test/snapshots"))
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.androidx.test.junit)
    testImplementation(libs.robolectric)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit.rule)
}
