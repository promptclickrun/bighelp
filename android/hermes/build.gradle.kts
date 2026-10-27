plugins {
    kotlin("jvm")
}
kotlin {
    jvmToolchain(17)
}
dependencies {
    // Public signatures expose JsonElement and coroutine types, so consumers see them.
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    // OkHttp stays an implementation detail: no public signature mentions its types.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
tasks.test {
    val wireVectors = rootProject.file("../docs/hermes/vectors/wire.json")
    // The tests read the shared vectors by path; declare the file so a content change reruns them.
    inputs.file(wireVectors).withPropertyName("wireVectors").withPathSensitivity(PathSensitivity.NONE)
    systemProperty("hermes.wireVectors", wireVectors.absolutePath)
}
