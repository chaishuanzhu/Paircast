// Jenkins job paircast-server (Pipeline script, not SCM): build, publish and deploy the Paircast server (server/).
//   Images  ci-01: paircast-server image of one commit, tagged sha-<7>, pushed to Docker Hub
//           (skipped when the tag already exists, unless REBUILD)
//   Deploy  ci-01: kubectl set image deployment/paircast in namespace go-im-test, rolls back on failure,
//           then checks that https://paircast.test.chaisz.com/media/sources is served by Paircast (401 without a token)
// The deployment, Secrets (goim-paircast, goim-paircast-config) and ingress already exist in go-im-test;
// see server/deploy/k8s. GO-IM itself is deployed by the go-im-server job.
//
// Parameters: BRANCH, DOCKERHUB_NAMESPACE (empty = dockerhub credential user), PLATFORMS, REBUILD, DEPLOY
// Credentials:
//   dockerhub                Username with password  Docker Hub user + Read & Write access token
//   k8s-deployer-kubeconfig  Secret file             ServiceAccount jenkins/deployer (edit in go-im-test)

def repoUrl = 'https://github.com/chaishuanzhu/Paircast.git'
def k8sNamespace = 'go-im-test'
def siteUrl = 'https://paircast.test.chaisz.com'
def commit = ''
def tag = ''
def imageNs = ''

stage('Resolve') {
    node('docker') {
        retry(3) {
            commit = sh(script: "git ls-remote ${repoUrl} refs/heads/${params.BRANCH}", returnStdout: true).trim().tokenize()[0] ?: ''
        }
        if (!(commit ==~ /[0-9a-f]{40}/)) { error "分支 ${params.BRANCH} 不存在" }
        tag = "sha-${commit.substring(0, 7)}"
        currentBuild.description = "${params.BRANCH} @ ${commit.substring(0, 7)}"
    }
}

stage('Image') {
    node('docker') {
        try {
            withCredentials([usernamePassword(credentialsId: 'dockerhub', usernameVariable: 'DH_USER', passwordVariable: 'DH_TOKEN')]) {
                imageNs = params.DOCKERHUB_NAMESPACE?.trim() ?: env.DH_USER
                withEnv(["NS=${imageNs}", "TAG=${tag}", "COMMIT=${commit}", "PLATFORMS=${params.PLATFORMS}"]) {
                    retry(3) {
                        sh 'echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin || { sleep 10; exit 1; }'
                    }
                    def exists = !params.REBUILD && sh(returnStatus: true, script: 'docker buildx imagetools inspect "$NS/paircast-server:$TAG" >/dev/null 2>&1') == 0
                    if (exists) {
                        echo "${imageNs}/paircast-server:${tag} 已存在，跳过构建"
                        return
                    }
                    deleteDir()
                    retry(3) {
                        checkout([
                            $class: 'GitSCM',
                            branches: [[name: commit]],
                            userRemoteConfigs: [[url: repoUrl, refspec: "+refs/heads/${params.BRANCH}:refs/remotes/origin/${params.BRANCH}"]],
                            extensions: [[$class: 'CloneOption', shallow: true, depth: 1, noTags: true, honorRefspec: true, timeout: 20]],
                        ])
                    }
                    dir('server') {
                        sh '''
                            set -eu
                            # Compile on the build host's architecture (Go cross-compiles by TARGETARCH) instead of
                            # running go build under QEMU for arm64.
                            sed -i -E 's#^FROM golang:([^ ]+) AS builder#FROM --platform=$BUILDPLATFORM golang:\\1 AS builder\\nARG TARGETOS TARGETARCH#' Dockerfile
                            sed -i -E 's#CGO_ENABLED=0 go build#CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build#' Dockerfile
                            for i in 1 2 3; do
                                docker buildx build --platform "$PLATFORMS" \
                                    --label org.opencontainers.image.source=https://github.com/chaishuanzhu/Paircast \
                                    --label org.opencontainers.image.revision="$COMMIT" \
                                    -t "$NS/paircast-server:$TAG" --push . && break
                                [ "$i" = 3 ] && exit 1
                                sleep 15
                            done
                        '''
                    }
                }
            }
        } finally {
            sh 'docker logout || true'
            deleteDir()
        }
    }
}

stage('Deploy') {
    if (!params.DEPLOY) {
        echo '跳过部署'
        return
    }
    node('docker') {
        withCredentials([file(credentialsId: 'k8s-deployer-kubeconfig', variable: 'KUBECONFIG')]) {
            withEnv(["NS=${imageNs}", "TAG=${tag}", "K8S_NS=${k8sNamespace}"]) {
                sh '''
                    set -eu
                    k() { kubectl -n "$K8S_NS" "$@"; }
                    k set image deployment/paircast "paircast=$NS/paircast-server:$TAG"
                    # Docker Hub pulls from the cluster nodes are slow at times.
                    if ! k rollout status deployment/paircast --timeout=10m; then
                        k get pods -o wide || true
                        k logs deployment/paircast --all-containers --tail=50 || true
                        k rollout undo deployment/paircast || true
                        echo "deployment/paircast 未就绪，已回滚"
                        exit 1
                    fi
                    k get pods -o wide
                '''
            }
        }
        withEnv(["SITE=${siteUrl}"]) {
            sh '''
                set -u
                for i in $(seq 1 12); do
                    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SITE/media/sources")
                    [ "$code" = 401 ] && { echo "/media/sources -> 401 (Paircast)"; exit 0; }
                    sleep 5
                done
                echo "检查失败：/media/sources 返回 $code（期望 401）"
                exit 1
            '''
        }
        currentBuild.description += " → ${k8sNamespace}"
    }
}
