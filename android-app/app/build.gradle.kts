import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val releaseKeystoreProps = Properties().apply {
    val candidateFiles = listOf(
        rootProject.file("keystore.properties"),
        file("${System.getProperty("user.home")}/.android/bridge-release.properties")
    )
    candidateFiles.firstOrNull { it.exists() }?.inputStream()?.use { load(it) }
}

val releaseStoreFilePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")
    ?: releaseKeystoreProps.getProperty("storeFile")
val releaseStorePassword: String? = System.getenv("ANDROID_KEYSTORE_PASSWORD")
    ?: releaseKeystoreProps.getProperty("storePassword")
val releaseKeyAlias: String? = System.getenv("ANDROID_KEY_ALIAS")
    ?: releaseKeystoreProps.getProperty("keyAlias")
val releaseKeyPassword: String? = System.getenv("ANDROID_KEY_PASSWORD")
    ?: releaseKeystoreProps.getProperty("keyPassword")

val releaseStoreFile = releaseStoreFilePath?.takeIf { it.isNotBlank() }?.let { file(it) }
val hasReleaseSigning = releaseStoreFile != null &&
    releaseStoreFile.exists() &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "com.link.clipboardsync"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.link.clipboardsync"
        minSdk = 26
        targetSdk = 34
        versionCode = 8
        versionName = "1.3.5"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
