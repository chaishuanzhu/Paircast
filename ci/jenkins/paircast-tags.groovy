// Jenkins job paircast-tags (Pipeline script): polls GitHub for new v<MAJOR.MINOR.PATCH> tags and starts
// paircast-server with TAG=<tag> for each one (server image X.Y.Z + latest, test deploy). The IPA and APK of the
// same tag are built by GitHub Actions. Jenkins is LAN-only, so GitHub webhooks cannot reach it.
// Known tags are kept on ci-01 in /data/jenkins-agent/state/paircast-tags.txt; the first run only records the existing
// tags. Delete a line from that file to release that tag again on the next poll.

def repoUrl = 'https://github.com/chaishuanzhu/Paircast.git'

node('docker') {
    def remote = ''
    retry(3) {
        remote = sh(returnStdout: true, script: "git ls-remote --tags --refs ${repoUrl} 'refs/tags/v*'").trim()
    }
    def current = remote ? remote.readLines().collect { it.replaceFirst(/.*refs\/tags\//, '') }.findAll { it ==~ /v[1-9][0-9]*\.[0-9]+\.[0-9]+/ } : []
    dir('/data/jenkins-agent/state') {
        if (!fileExists('paircast-tags.txt')) {
            writeFile file: 'paircast-tags.txt', text: current.join('\n') + '\n'
            currentBuild.description = "baseline: ${current.join(', ') ?: '(none)'}"
            return
        }
        def known = readFile('paircast-tags.txt').readLines().collect { it.trim() }.findAll { it }
        def fresh = current.findAll { !known.contains(it) }
        if (!fresh) {
            currentBuild.description = 'no new tags'
            currentBuild.result = 'NOT_BUILT'
            return
        }
        for (t in fresh) {
            build job: 'paircast-server', wait: false, parameters: [string(name: 'TAG', value: t)]
            echo "started paircast-server for ${t}"
        }
        writeFile file: 'paircast-tags.txt', text: (known + fresh).join('\n') + '\n'
        currentBuild.description = "started paircast-server: ${fresh.join(', ')}"
    }
}
