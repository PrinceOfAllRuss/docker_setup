#!/bin/bash
# Chose one of them:
/home/wait-for-it.sh postgres:5432 -s -t 60
java -jar -Xmx4g /opt/application/app.jar