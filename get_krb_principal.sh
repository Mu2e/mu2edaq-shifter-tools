#!/usr/bin/env bash
# Script to Pull the Kerberos principle from the active cache
#
# Need to parse to pull off the actual principal
# Since we are only interested in FNAL.GOV principals we just 
# grep this out
export KRB5_PRINCIPAL=$(klist -l | grep "FNAL.GOV" | awk '{print $1}')
#echo "MYVAR=$KRB5_PRINCIPAL" > /tmp/krb5_principal.txt
#source /tmp/krb5_principal.txt

