#!/bin/bash

# Usage: ./deleteOld.sh 7

aws --endpoint-url $AWS_ENDPOINT_URL s3 ls $DB_DUMP_TARGET/ | grep " PRE " -v | while read -r line;
  do
    createDate=`echo $line|awk {'print $1" "$2'}`
    createDate=$(date -d "$createDate" "+%s")
    olderThan=$(date -d "@$(( $(busybox date +%s) - 86400 * $1 ))" +%s)
    if [[ $createDate -le $olderThan ]];
      then
        fileName=`echo $line|awk {'print $4'}`
        if [ $fileName != "" ]
          then
            printf 'Deleting "%s"\n' "$DB_DUMP_TARGET/$fileName"
            aws --endpoint-url $AWS_ENDPOINT_URL s3 rm "$DB_DUMP_TARGET/$fileName"
        fi
    fi
  done;