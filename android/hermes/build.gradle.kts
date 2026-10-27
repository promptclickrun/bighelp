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
    // OkHttp carries the bounded HTTP only; no public signature mentions its types.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // The gateway WebSocket needs real inbound bounds and strict UTF-8, which OkHttp 4.12 cannot give (it assembles
    // a whole message before delivering it and repairs bad UTF-8). Java-WebSocket checks a frame's declared length
    // before allocating and caps the sum of fragments. Pinned; no extensions (no permessage-deflate) are configured.
    implementation("org.java-websocket:Java-WebSocket:1.6.0")
    // The library logs frames at trace level. Bind SLF4J to its no-op provider so frame and token data can never
    // reach a log, whatever else is on an app's classpath at build time. (slf4j-api 2.0.13 arrives with the library.)
    runtimeOnly("org.slf4j:slf4j-nop:2.0.13")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    // Real certificates for the TLS negative/hostname tests.
    testImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
}
tasks.test {
    val wireVectors = rootProject.file("../docs/hermes/vectors/wire.json")
    // The tests read the shared vectors by path; declare the file so a content change reruns them.
    inputs.file(wireVectors).withPropertyName("wireVectors").withPathSensitivity(PathSensitivity.NONE)
    systemProperty("hermes.wireVectors", wireVectors.absolutePath)
}
