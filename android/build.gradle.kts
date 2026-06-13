allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some plugins (e.g. flutter_quick_video_encoder) still compile against an older
// Android SDK while others now require compileSdk 36. Force every plugin Android
// subproject to compile against 36 so the AAR metadata check passes. Registered
// before evaluationDependsOn(":app") and skipping ":app" (already on 36) to
// avoid registering afterEvaluate on an already-evaluated project.
subprojects {
    if (project.name != "app") {
        afterEvaluate {
            extensions.findByName("android")?.let { ext ->
                val androidExt = ext as com.android.build.gradle.BaseExtension
                val current = androidExt.compileSdkVersion
                    ?.substringAfter("android-")?.toIntOrNull() ?: 0
                if (current < 36) androidExt.compileSdkVersion(36)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
