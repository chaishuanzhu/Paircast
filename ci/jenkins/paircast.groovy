// Jenkins job paircast (Pipeline script, not SCM): build and publish the Paircast apps and server.
//   Release  TAG=vX.Y.Z (started by paircast-tags when the tag is pushed). The tag must be on main and the release
//            commit must already carry the version numbers and the store copy (Scripts/release.sh check / on-main):
//              node-mac         shared Kotlin tests; App Store signed IPA → TestFlight (internal group + External
//                               Testers, submitted for beta review, What to Test = metadata whatsNew); signed APK
//              paircast-server  image 870027381/paircast-server:X.Y.Z + latest, Docker Hub overview, test deploy
//              node-mac         GitHub Release vX.Y.Z (IPA + APK, body from Scripts/release.sh notes), then
//                               docs/source.json (LiveContainer source) regenerated and pushed to main
//   Test     TAG empty: the head of BRANCH. IPA build number <CURRENT_PROJECT_VERSION - 1>.<Jenkins build number>
//            (above the previous release, below the next one) → TestFlight internal group only, no review;
//            APK versionName X.Y.Z-test.<Jenkins build number>; artifacts stay in Jenkins (no GitHub Release);
//            server image sha-<7> deployed to the test environment
// Each node checks out the same commit; the controller does not check out (flaky network to GitHub).
//
// Parameters: TAG, BRANCH, BUILD_IOS, BUILD_ANDROID, BUILD_SERVER, TESTFLIGHT, SUBMIT_REVIEW (TAG only),
//             PUBLISH (TAG only), DEPLOY_TEST
// Credentials:
//   paircast-ios-keychain-password  Secret text             password of ~/Library/Keychains/iOSDevKeychain-db on
//                                                           node-mac (Apple Distribution cert, iosApp/fastlane)
//   paircast-android-keystore       Secret file             Android release keystore (PKCS12)
//   paircast-android-signing        Username with password  username = key alias, password = keystore / key password
//   goim-asc-api-key                Secret file             App Store Connect API key (.p8), same team 8PHCHYD8X3
//   goim-asc-api-ids                Username with password  username = Key ID, password = Issuer ID
//   github-token                    Secret text             GitHub token with contents:write on chaishuanzhu/Paircast
//   (paircast-server job: dockerhub, k8s-deployer-kubeconfig)

def repoUrl = 'https://github.com/chaishuanzhu/Paircast.git'
def ascAppId = '6798781578'
def tfInternalGroup = '7b2141f6-0288-4845-b1b3-ca1075089579'   // 内部测试 (internal, no review)
def tfExternalGroup = 'a9ad43d6-e364-4a50-9628-7c29ba3903c7'   // External Testers (public link)
def gitTag = params.TAG?.trim() ?: ''
def branch = params.BRANCH?.trim() ?: 'main'
def sourceRef = "refs/heads/${branch}"
if (gitTag) {
    if (!(gitTag ==~ /v[1-9][0-9]*\.[0-9]+\.[0-9]+/)) { error "TAG 应为 vX.Y.Z：${gitTag}" }
    sourceRef = "refs/tags/${gitTag}"
}
def commit = ''
def version = ''
def buildNumber = ''
def label = ''

def checkoutCommit(String repoUrl, String ref, String commit) {
    def local = ref.startsWith('refs/tags/') ? ref : ref.replaceFirst('refs/heads/', 'refs/remotes/origin/')
    deleteDir()
    retry(3) {
        checkout(changelog: false, poll: false, scm: [
            $class: 'GitSCM',
            branches: [[name: commit]],
            userRemoteConfigs: [[url: repoUrl, refspec: "+${ref}:${local}"]],
            extensions: [[$class: 'CloneOption', shallow: true, depth: 1, noTags: true, honorRefspec: true, timeout: 20]],
        ])
    }
}

stage('Resolve') {
    node('docker') {
        try {
            retry(3) {
                // Annotated tags: the ^{} line is the commit the tag points to.
                def refs = sh(script: "git ls-remote ${repoUrl} '${sourceRef}' '${sourceRef}^{}'", returnStdout: true).trim()
                def rows = refs ? refs.readLines().collect { it.tokenize('\t') } : []
                def row = rows.find { it[1].endsWith('^{}') } ?: (rows ? rows[0] : null)
                commit = row ? row[0] : ''
            }
            if (!(commit ==~ /[0-9a-f]{40}/)) { error "${sourceRef} 不存在" }
            checkoutCommit(repoUrl, sourceRef, commit)
            version = sh(returnStdout: true, script: '''sed -n 's/.*"MARKETING_VERSION": "\\([^"]*\\)".*/\\1/p' iosApp/Project.swift | head -1''').trim()
            buildNumber = sh(returnStdout: true, script: '''sed -n 's/.*"CURRENT_PROJECT_VERSION": "\\([^"]*\\)".*/\\1/p' iosApp/Project.swift | head -1''').trim()
            if (!(buildNumber ==~ /[1-9][0-9]*/)) { error "CURRENT_PROJECT_VERSION 应为正整数：${buildNumber}" }
            if (gitTag) {
                withCredentials([string(credentialsId: 'github-token', variable: 'GH_TOKEN')]) {
                    sh "bash Scripts/release.sh check '${gitTag}' && bash Scripts/release.sh on-main '${gitTag}'"
                }
                label = gitTag
            } else {
                label = "${version}-test.${env.BUILD_NUMBER}"
            }
            currentBuild.description = "${gitTag ?: branch} @ ${commit.substring(0, 7)}" + (gitTag ? '' : " (${label})")
        } finally {
            deleteDir()
        }
    }
}

def branches = [:]

if (params.BUILD_IOS || params.BUILD_ANDROID) {
    branches['iOS + Android'] = {
        node('node-mac') {
            try {
                checkoutCommit(repoUrl, sourceRef, commit)
                def iosBuild = gitTag ? buildNumber : "${Integer.parseInt(buildNumber) - 1}.${env.BUILD_NUMBER}"
                def gradleArgs = '--console=plain --no-daemon --no-configuration-cache' +
                    (gitTag ? '' : " -Ppaircast.versionName=${label}")
                withEnv([
                    'LANG=en_US.UTF-8',
                    'LC_ALL=en_US.UTF-8',
                    // Gradle needs JDK 17–21; the system JDK is newer.
                    'JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home',
                    'ANDROID_HOME=/Users/chaisz/Library/Android/sdk',
                    "BUNDLE_PATH=${env.HOME}/.jenkins_home/caches/paircast-bundle",
                    "GRADLE_ARGS=${gradleArgs}",
                    "LABEL=${label}",
                    "IOS_BUILD=${iosBuild}",
                ]) {
                    sh 'rm -rf dist && mkdir -p dist'
                    stage('Shared tests') {
                        sh './gradlew $GRADLE_ARGS :shared:core:testDebugUnitTest :shared:data:testDebugUnitTest'
                    }
                    stage('Android') {
                        if (!params.BUILD_ANDROID) { echo '跳过'; return }
                        withCredentials([
                            file(credentialsId: 'paircast-android-keystore', variable: 'PAIRCAST_KEYSTORE_FILE'),
                            usernamePassword(credentialsId: 'paircast-android-signing', usernameVariable: 'PAIRCAST_KEY_ALIAS', passwordVariable: 'PAIRCAST_KEYSTORE_PASSWORD'),
                        ]) {
                            sh '''
                                export PAIRCAST_KEY_PASSWORD="$PAIRCAST_KEYSTORE_PASSWORD"
                                ./gradlew $GRADLE_ARGS :androidApp:assembleRelease
                                code=$(sed -n 's/^paircast\\.versionCode=//p' gradle.properties)
                                cp androidApp/build/outputs/apk/release/androidApp-release.apk "dist/Paircast-$LABEL-build$code.apk"
                            '''
                        }
                    }
                    stage('iOS') {
                        if (!params.BUILD_IOS) { echo '跳过'; return }
                        withCredentials([string(credentialsId: 'paircast-ios-keychain-password', variable: 'KEYCHAIN_PASSWORD')]) {
                            sh '''
                                set -e
                                sed -i '' -E "s/(\\"CURRENT_PROJECT_VERSION\\": \\")[^\\"]*/\\1$IOS_BUILD/" iosApp/Project.swift
                                ./iosApp/Scripts/download-vlckit.sh
                                cd iosApp
                                bundle install --jobs 4 --retry 3
                                rm -rf Tuist/.build
                                tuist install
                                tuist generate --no-open
                                bundle exec fastlane archive_appstore
                                cd ..
                                built=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' .asc/artifacts/Paircast.xcarchive/Info.plist)
                                [ "$built" = "$IOS_BUILD" ] || { echo "IPA 构建号 $built ≠ $IOS_BUILD"; exit 1; }
                                cp .asc/artifacts/Paircast.ipa "dist/Paircast-$LABEL-build$IOS_BUILD.ipa"
                            '''
                        }
                    }
                    archiveArtifacts artifacts: 'dist/*', fingerprint: true, allowEmptyArchive: true
                    stash name: 'dist', includes: 'dist/*', allowEmpty: true
                    stage('TestFlight') {
                        if (!params.BUILD_IOS || !params.TESTFLIGHT) { echo '跳过'; return }
                        def submit = gitTag && params.SUBMIT_REVIEW
                        def notes = gitTag ?
                            sh(returnStdout: true, script: "bash Scripts/release.sh whats-new '${gitTag}' zh-Hans").trim() :
                            "测试包 ${label}（${branch} @ ${commit.substring(0, 7)}，Jenkins #${env.BUILD_NUMBER}）"
                        writeFile file: 'testflight-notes.txt', text: notes
                        withCredentials([
                            file(credentialsId: 'goim-asc-api-key', variable: 'ASC_PRIVATE_KEY_PATH'),
                            usernamePassword(credentialsId: 'goim-asc-api-ids', usernameVariable: 'ASC_KEY_ID', passwordVariable: 'ASC_ISSUER_ID'),
                        ]) {
                            withEnv([
                                "APP_ID=${ascAppId}",
                                "GROUPS=${gitTag ? "${tfInternalGroup},${tfExternalGroup}" : tfInternalGroup}",
                                "SUBMIT=${submit ? '--submit --confirm' : ''}",
                            ]) {
                                // The agent cannot read the API key asc stored in the login keychain.
                                sh '''
                                    export ASC_BYPASS_KEYCHAIN=1
                                    asc publish testflight --app "$APP_ID" --ipa dist/Paircast-*.ipa --group "$GROUPS" \
                                        --wait --timeout 90m --test-notes "$(cat testflight-notes.txt)" --locale zh-Hans $SUBMIT
                                '''
                            }
                        }
                        currentBuild.description += submit ? ' → TestFlight 审核' : ' → TestFlight'
                    }
                }
            } finally {
                deleteDir()
            }
        }
    }
}

if (params.BUILD_SERVER) {
    branches['Server'] = {
        def p = [booleanParam(name: 'DEPLOY', value: params.DEPLOY_TEST)]
        p << (gitTag ? string(name: 'TAG', value: gitTag) : string(name: 'BRANCH', value: branch))
        def b = build job: 'paircast-server', parameters: p
        echo "paircast-server #${b.number}: ${b.description ?: ''}"
    }
}

stage('Build') {
    timeout(time: 3, unit: 'HOURS') {
        parallel branches
    }
}

stage('Publish') {
    if (!gitTag || !params.PUBLISH || !(params.BUILD_IOS || params.BUILD_ANDROID)) {
        echo gitTag ? '跳过 GitHub Release' : '测试包不发布 GitHub Release，产物见本次构建的 Artifacts'
        return
    }
    node('node-mac') {
        try {
            checkoutCommit(repoUrl, sourceRef, commit)
            unstash 'dist'
            withCredentials([string(credentialsId: 'github-token', variable: 'GH_TOKEN')]) {
                withEnv(["TAG=${gitTag}"]) {
                    retry(3) {
                        sh 'bash Scripts/release.sh publish "$TAG" dist/*'
                    }
                    // LiveContainer / AltStore source on GitHub Pages lists the IPAs of all releases.
                    retry(3) {
                        sh '''
                            set -eu
                            git() { command git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
                            rm -rf pages
                            git clone -q --depth 1 -b main https://github.com/chaishuanzhu/Paircast.git pages
                            bash Scripts/update-livecontainer-source.sh pages/docs/source.json
                            cd pages
                            git add docs/source.json
                            if git diff --cached --quiet; then echo 'LiveContainer source unchanged'; exit 0; fi
                            git -c user.name='Paircast Jenkins' -c user.email='jenkins@chaisz.com' \
                                commit -q -m "chore: update LiveContainer source for $TAG"
                            git push origin HEAD:main
                        '''
                    }
                }
            }
            currentBuild.description += ' → GitHub Release'
        } finally {
            deleteDir()
        }
    }
}
