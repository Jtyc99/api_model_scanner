// The report parser, with no IntelliJ dependency of any kind.
//
// Kept a separate module so that is enforced by the build rather than by
// discipline — the same property that lets `report.ts` be tested without a
// VS Code host. These tests run in a plain JVM, in milliseconds.
plugins {
  kotlin("jvm")
}

repositories { mavenCentral() }

dependencies {
  compileOnly(kotlin("stdlib"))
  testImplementation(kotlin("stdlib"))
  testImplementation(kotlin("test"))
}

kotlin { jvmToolchain(17) }

tasks.test { useJUnitPlatform() }
