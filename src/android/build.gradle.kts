import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

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
    // Compile Flutter Android plugins against the same API level as the app.
    // Several current AndroidX artifacts require API 34+, while older plugin
    // templates still declare compileSdk 33 and fail AAR metadata validation.
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension> {
            finalizeDsl { androidExtension ->
                androidExtension.compileSdk = 37
            }
        }
    }
    // file_picker 11 skips its Kotlin plugin on AGP 9, expecting built-in
    // Kotlin. Flutter's legacy DSL compatibility mode disables that built-in
    // compiler, so re-enable the Kotlin plugin for this module explicitly.
    if (name == "file_picker") {
        pluginManager.apply("org.jetbrains.kotlin.android")
        tasks.withType<KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
