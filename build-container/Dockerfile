FROM amazonlinux:latest

#
# versions
#

ARG KUBECTL_VERSION=1.21.0 

USER root

#
# tools
#

RUN yum update -y && \
    yum install -y aws-cli jq python3-pip tar gzip && \
    pip3 install yq

#
# kubectl
#

RUN mkdir -p /opt/kubectl && \
    cd /opt/kubectl && curl --silent -LO "https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod 0755 /opt/kubectl/kubectl && \
    ln -s /opt/kubectl/kubectl /usr/local/bin 


#
# cleanup
#

RUN yum clean all && rm -rf /var/cache/yum

# to 
COPY run.sh /tmp