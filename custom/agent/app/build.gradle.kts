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
    // 仍只用平台 API（org.json / HttpURLConnection / AndroidKeyStore / 无障碍服务），
    // 不引入第三方运行时依赖；加密存储用 Keystore 自实现（见 SecurePrefs）。
    testImplementation("junit:junit:4.13.2")
}
