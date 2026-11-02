package com.chaisz.paircast.data.files

import okio.FileSystem
import okio.Path
import okio.Path.Companion.toPath

internal expect val systemFileSystem: FileSystem

/** Writes / reads files under the platform cache or app-support directory. */
class FileStore(rootDirectory: String, private val fs: FileSystem = systemFileSystem) {
    val root: Path = rootDirectory.toPath()

    fun write(relative: String, bytes: ByteArray): String {
        val path = root / relative
        path.parent?.let { fs.createDirectories(it) }
        val tmp = "$path.tmp".toPath()
        fs.write(tmp) { write(bytes) }
        fs.atomicMove(tmp, path)
        return path.toString()
    }

    fun read(relative: String): ByteArray? {
        val path = root / relative
        return if (fs.exists(path)) fs.read(path) { readByteArray() } else null
    }

    fun readAbsolute(path: String): ByteArray = fs.read(path.toPath()) { readByteArray() }

    fun deleteAll() {
        if (fs.exists(root)) fs.deleteRecursively(root)
    }
}
