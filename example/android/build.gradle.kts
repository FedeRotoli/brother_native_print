allprojects {
    repositories {
        google()
        mavenCentral()
        // Repository Maven locale con l'AAR dell'SDK Brother, dichiarato nel
        // progetto plugin. Va registrato anche qui perché le dipendenze dei
        // plugin inclusi come subproject vengono risolte con i repository
        // del progetto root dell'app host.
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
