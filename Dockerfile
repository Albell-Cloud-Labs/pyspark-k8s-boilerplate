FROM ubuntu:18.04

# toggle these versions judiciously, there are downstream effects and
# interactions between them
ENV HADOOP_VERSION=3.2.2 \
    SPARK_VERSION=3.1.2 \
    SCALA_VERSION=2.12.0 \
    PYTHON_VERSION=3.9 \
    JDK_VERSION=8

# Specify the user that the main process will run as
#ARG spark_uid=185

# Add packages and configure based on official spark-on-k8s dockerfile
ENV TINI_VERSION v0.19.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini \
    /usr/bin/tini
RUN chmod +x /usr/bin/tini

RUN set -ex && \
    apt-get update && \
    apt-get install -y libc6 libpam-modules krb5-user libnss3 procps && \
    ln -s /lib /lib64 && \
    rm /bin/sh && \
    ln -sv /bin/bash /bin/sh && \
    echo "auth required pam_wheel.so use_uid" >> /etc/pam.d/su && \
    chgrp root /etc/passwd && chmod ug+rw /etc/passwd && \
    rm -rf /var/cache/apt/*

# change shell to bash which supports parameter expansion
SHELL ["/bin/bash", "-c"]

# install some essential utilities
RUN apt-get update && apt-get install curl -y && apt-get install vim -y

# install python and pip
RUN apt-get install software-properties-common -y && \
    add-apt-repository ppa:deadsnakes/ppa -y && apt-get update && \
    export DEBIAN_FRONTEND="noninteractive" && \
    apt-get install -y python${PYTHON_VERSION} python${PYTHON_VERSION:0:1}-pip && \
    apt-get install -y python${PYTHON_VERSION}-distutils

# install jdk
RUN apt-get install openjdk-${JDK_VERSION}-jdk -y

# install scala
RUN apt-get install wget -y && \
    wget www.scala-lang.org/files/archive/scala-${SCALA_VERSION}.deb && \
    dpkg -i scala-${SCALA_VERSION}.deb

# install spark
RUN export SPARK_PRE=https://mirrors.sonic.net/apache/spark/spark- && \
    export \
    SPARK_TAR=spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION:0:3}.tgz && \
    wget ${SPARK_PRE}${SPARK_VERSION}/${SPARK_TAR} && \
    tar xvf ${SPARK_TAR} && \
    mv ${SPARK_TAR:0:-4} /opt/spark && \
    mkdir -p /opt/spark/work-dir && \
    cp -r /opt/spark/kubernetes/tests /opt/spark/tests && \
    cp /opt/spark/kubernetes/dockerfiles/spark/entrypoint.sh /opt/ && \
    cp /opt/spark/kubernetes/dockerfiles/spark/decom.sh /opt/

ENV SPARK_HOME=/opt/spark \
    PATH=$PATH:/opt/spark/bin \
    PYSPARK_PYTHON=/usr/bin/python${PYTHON_VERSION}

# download and install hadoop
ENV HADOOP_URL_PRE http://archive.apache.org/dist/hadoop/common/hadoop-
RUN mkdir -p /opt && \
    cd /opt && \
    curl ${HADOOP_URL_PRE}${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz | \
        tar -zx hadoop-${HADOOP_VERSION}/lib/native && \
    ln -s hadoop-${HADOOP_VERSION} hadoop

ADD spark-defaults.conf /opt/spark/conf/spark-defaults.conf

###############################################################################
# Cloud provider specific configuration -- modify, remove, or replace with    #
# your provider of choice                                                     #
###############################################################################

# set GCP project
ARG gcp_project

# install gcloud client and hadoop storage connector
ENV GCS_LIB_VERS=2.2.2 \
    GCS_URL=https://storage.googleapis.com/hadoop-lib/gcs/ \
    JAR_PATH=/jars/gcs-connector-hadoop
RUN curl https://dl.google.com/dl/cloudsdk/release/google-cloud-sdk.tar.gz \
    > /tmp/google-cloud-sdk.tar.gz && \
    curl \
    ${GCS_URL}gcs-connector-hadoop${HADOOP_VERSION:0:1}-${GCS_LIB_VERS}.jar \
    > ${SPARK_HOME}${JAR_PATH}${HADOOP_VERSION:0:1}-${GCS_LIB_VERS}.jar && \
    mkdir -p /usr/local/gcloud \
    && tar -C /usr/local/gcloud -xvf /tmp/google-cloud-sdk.tar.gz \
    && /usr/local/gcloud/google-cloud-sdk/install.sh

ENV PATH $PATH:/usr/local/gcloud/google-cloud-sdk/bin

# activate gcloud service account (but use better secret management in prod...)
ADD secrets/key-file /key-file
RUN gcloud auth activate-service-account --key-file=/key-file

# set service account authentication as application default credentials if you
# want to use it in context of other libs
ENV GOOGLE_APPLICATION_CREDENTIALS /key-file

# set default project
RUN gcloud config set project ${gcp_project}

###############################################################################
# Cloud specific configuration done                                           #
###############################################################################

# some final housekeeping from official spark-on-k8s dockerfile
WORKDIR /opt/spark/work-dir
RUN chmod g+w /opt/spark/work-dir
RUN chmod a+x /opt/decom.sh
ADD . /opt/spark/work-dir
RUN apt-get install -y python3-venv
RUN pip3 install build
RUN python${PYTHON_VERSION} -m pip install --upgrade setuptools
RUN curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
RUN python${PYTHON_VERSION} get-pip.py
RUN make clean-install
#TODO need to reorganize this last bit, also avoid using the wrong build version (i think its 3.6 rn)

ENTRYPOINT [ "/opt/entrypoint.sh" ]

#USER ${spark_uid}
