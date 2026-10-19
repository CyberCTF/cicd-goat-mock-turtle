// Seed jobs (run by Configuration-as-Code) for Wonderland's mock-turtle repository.
//
// This is CICD-SEC-1, Insufficient Flow Control: an AUTO-MERGE bot is the only control between a
// pull request and the protected main branch, and its merge rule is trivially bypassed.
//
//   mock-turtle-automerge  The auto-merge bot. Runs every minute, lists open pull requests and
//                          merges each one whose change looks like a harmless version bump: it adds
//                          no NET words, the `version` file keeps its dotted structure, and the
//                          `version` file is among the changed files. The real logic (the three
//                          checks + the Gitea merge call) lives in a reviewable baked script,
//                          /usr/local/bin/mock-turtle-automerge, bound to the bot's write credential.
//
//   mock-turtle            The main build. A Pipeline read FROM the repository's own Jenkinsfile on
//                          the main branch, polled over git every minute. Pull-request branches are
//                          never built here, so the ONLY way an attacker's change runs is after the
//                          bot merges it onto main — at which point this pipeline runs the poisoned
//                          Jenkinsfile and the Global-scope flag10 credential it binds is exfiltrated.

pipelineJob('mock-turtle-automerge') {
    displayName('Wonderland » mock-turtle (auto-merge bot)')
    description('Auto-merges tidy version-bump pull requests to main. Runs every minute.')
    triggers {
        cron('* * * * *')
    }
    definition {
        cps {
            sandbox(true)
            script('''
pipeline {
    agent any
    options {
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }
    stages {
        stage('Auto-merge tidy pull requests') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'mock-turtle-token', usernameVariable: 'MT_USER', passwordVariable: 'MT_PASS')]) {
                    sh 'bash /usr/local/bin/mock-turtle-automerge'
                }
            }
        }
    }
    post {
        always {
            cleanWs()
        }
    }
}
'''.stripIndent())
        }
    }
}

pipelineJob('mock-turtle') {
    displayName('Wonderland » mock-turtle (build main)')
    description('Builds the main branch of mock-turtle from its own Jenkinsfile. Polls git every minute.')
    triggers {
        scm('* * * * *')
    }
    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('http://gitea:3000/Wonderland/mock-turtle.git')
                        credentials('gitea-jenkins')
                    }
                    branch('*/main')
                }
            }
            scriptPath('Jenkinsfile')
            lightweight(false)
        }
    }
}
