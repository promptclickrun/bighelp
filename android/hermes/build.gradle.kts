plugins {
    kotlin("jvm")
}
kotlin {
    jvmToolchain(17)
}
dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation("junit:junit:4.13.2")
}
tasks.test {
    val wireVectors = rootProject.file("../docs/hermes/vectors/wire.json")
    // The tests read the shared vectors by path; declare the file so a content change reruns them.
    inputs.file(wireVectors).withPropertyName("wireVectors").withPathSensitivity(PathSensitivity.NONE)
    systemProperty("hermes.wireVectors", wireVectors.absolutePath)
}
