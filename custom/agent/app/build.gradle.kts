plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.pocketvm.aiagent"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.pocketvm.aiagent"
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
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
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // 只用平台 API（org.json / HttpURLConnection / su），不引入第三方依赖
}
