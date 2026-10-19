# Wonderland's Jenkins controller. Configured entirely by Configuration-as-Code (casc/jenkins.yaml)
# with a Job DSL seed that creates two git-polling pipelines: the auto-merge bot and the main build.
# The flag is NOT here: the flag10 credential resolves at boot from a file the entrypoint stages out
# of the per-player input Isoloom mounts at run time. Runs as root so the entrypoint can read that
# root-only mounted secret; builds execute on the controller's own executor (`agent any`), which is
# where the poisoned main pipeline binds and exfiltrates flag10.
FROM jenkins/jenkins:lts-jdk21

USER root

# git + curl for SCM polling and the in-controller bot/solver; jq so the auto-merge bot can parse
# the Gitea pull-request API. The base image already ships git for SCM.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates jq \
 && rm -rf /var/lib/apt/lists/*

# Plugins (resolved for this controller version).
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration-as-Code + the Job DSL seed, outside JENKINS_HOME so they are read as-is at boot.
COPY casc/ /usr/share/jenkins/casc/

COPY entrypoint.sh /usr/local/bin/mt-jenkins-entrypoint.sh
COPY automerge.sh /usr/local/bin/mock-turtle-automerge
COPY solve.sh /usr/local/bin/mock-turtle-solve
RUN chmod 0755 /usr/local/bin/mt-jenkins-entrypoint.sh /usr/local/bin/mock-turtle-automerge /usr/local/bin/mock-turtle-solve

ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/casc/jenkins.yaml \
    SECRETS=/run/lab/casc_secrets \
    JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xmx1024m"

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/mt-jenkins-entrypoint.sh"]
