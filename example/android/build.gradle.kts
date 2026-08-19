allprojects {
    repositories {
        google()
        mavenCentral()
        // Local Maven repository containing the Brother SDK AAR, declared in
        // the plugin project. It must be registered here as well because the
        // dependencies of plugins included as subprojects are resolved using
        // the root project's repositories of the host app.
        maven { url = uri("${rootProject.projectDir}/../../android/maven-repo") }
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
