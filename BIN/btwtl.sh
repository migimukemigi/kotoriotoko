#!/bin/sh

######################################################################
#
# BTWTL.SH : View The Twitter Timeline of A User (on Bearer Token Mode)
#
# Written by Shell-Shoccar Japan (@shellshoccarjpn) on 2020-11-09
#
# This is a public-domain software (CC0). It means that all of the
# people can use this for any purposes with no restrictions at all.
# By the way, We are fed up with the side effects which are brought
# about by the major licenses.
#
######################################################################


######################################################################
# Initial Configuration
######################################################################

# === Initialize shell environment ===================================
set -u
umask 0022
export LC_ALL=C
export PATH="$(command -p getconf PATH 2>/dev/null)${PATH+:}${PATH-}"
case $PATH in :*) PATH=${PATH#?};; esac
export UNIX_STD=2003  # to make HP-UX conform to POSIX

# === Define the functions for printing usage and error message ======
print_usage_and_exit () {
  cat <<-USAGE 1>&2
	Usage   : ${0##*/} [options] [loginname]
	Options : -m <max_ID>  |--maxid=<max_ID>
	          -n <count>   |--count=<count>
	          -s <since_ID>|--sinceid=<since_ID>
	          -v           |--verbose
	          --rawout=<filepath_for_writing_JSON_data>
	          --timeout=<waiting_seconds_to_connect>
	Version : 2020-11-09 05:58:55 JST
	USAGE
  check_my_bearer_token_and_print || exit $?
  exit 1
}
check_my_bearer_token_and_print() {
  case "${MY_bearer:-}" in '')
    echo '*** Bearer token is missing (you must set it into $MY_bearer)' 2>&1
    return 255
    ;;
  esac
  return 0
}
error_exit() {
  ${2+:} false && echo "${0##*/}: $2" 1>&2
  exit $1
}

# === Detect home directory of this app. and define more =============
Homedir="$(d=${0%/*}/; [ "_$d" = "_$0/" ] && d='./'; cd "$d.."; pwd)"
PATH="$Homedir/UTL:$Homedir/TOOL:$PATH" # for additional command
. "$Homedir/CONFIG/COMMON.SHLIB"        # account infomation

# === Confirm that the required commands exist =======================
# --- 1.cURL or Wget
if   type curl    >/dev/null 2>&1; then
  CMD_CURL='curl'
elif type wget    >/dev/null 2>&1; then
  CMD_WGET='wget'
else
  error_exit 1 'No HTTP-GET/POST command found.'
fi


######################################################################
# Argument Parsing
######################################################################

# === Print usage and exit if one of the help options is set =========
case "$# ${1:-}" in
  '1 -h'|'1 --help'|'1 --version') print_usage_and_exit;;
esac

# === Initialize parameters ==========================================
scname=''
count=''
max_id=''
since_id=''
verbose=0
rawoutputfile=''
timeout=''

# === Read options ===================================================
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --count=*)   count=$(printf '%s' "${1#--count=}" | tr -d '\n')
                 shift
                 ;;
    -n)          case $# in 1) error_exit 1 'Invalid -n option';; esac
                 count=$(printf '%s' "$2" | tr -d '\n')
                 shift 2
                 ;;
    --maxid=*)   max_id=$(printf '%s' "${1#--maxid=}" | tr -d '\n')
                 shift
                 ;;
    -m)          case $# in 1) error_exit 1 'Invalid -m option';; esac
                 max_id=$(printf '%s' "$2" | tr -d '\n')
                 shift 2
                 ;;
    --sinceid=*) since_id=$(printf '%s' "${1#--sinceid=}" | tr -d '\n')
                 shift
                 ;;
    -s)          case $# in 1) error_exit 1 'Invalid -s option';; esac
                 since_id=$(printf '%s' "$2" | tr -d '\n')
                 shift 2
                 ;;
    --verbose)   verbose=1
                 shift
                 ;;
    -v)          verbose=1
                 shift
                 ;;
    --rawout=*)  rawoutputfile=$(printf '%s' "${1#--rawout=}" | tr -d '\n')
                 shift
                 ;;
    --timeout=*) timeout=$(printf '%s' "${1#--timeout=}" | tr -d '\n')
                 shift
                 ;;
    --)          shift
                 break
                 ;;
    -)           break
                 ;;
    --*|-*)      error_exit 1 'Invalid option'
                 ;;
    *)           break
                 ;;
  esac
done
printf '%s\n' "$count" | grep -q '^[0-9]*$' || {
  error_exit 1 'Invalid -n option'
}
printf '%s\n' "$max_id" | grep -q '^[0-9]*$' || {
  error_exit 1 'Invalid -m option'
}
printf '%s\n' "$since_id" | grep -q '^[0-9]*$' || {
  error_exit 1 'Invalid -s option'
}
printf '%s\n' "$timeout" | grep -q '^[0-9]*$' || {
  error_exit 1 'Invalid --timeout option'
}

# === Get the loginname (screen name) ================================
case $# in
  0) case "${MY_scname:-}" in '')
       error_exit 1 'No screen name is set (you must set it into $MY_scname)'
       ;;
     esac
     scname=$MY_scname                          ;;
  1) scname=$(printf '%s' "${1#@}" | tr -d '\n')
     [ -z "$scname" ] && scname=$MY_scname      ;;
  *) print_usage_and_exit                       ;;
esac
printf '%s\n' "$scname" | grep -Eq '^[A-Za-z0-9_]+$' || {
  print_usage_and_exit
}


######################################################################
# Main Routine
######################################################################

# === Set parameters of Twitter API endpoint =========================
# (1)endpoint
API_endpt='https://api.twitter.com/1.1/statuses/user_timeline.json'
API_methd='GET'
# (2)parameters
API_param=$(cat <<-PARAM                   |
				count=${count}
				screen_name=@${scname}
				max_id=${max_id}
				since_id=${since_id}
				tweet_mode=extended
				PARAM
            grep -v '^[A-Za-z0-9_]\{1,\}=$')
readonly API_param

# === Pack the parameters for the API ================================
# --- 1.URL-encode only the right side of "="
#       (note: This string is also used to generate OAuth 1.0 signature)
apip_enc=$(printf '%s\n' "${API_param}" |
           grep -v '^$'                 |
           urlencode -r                 |
           sed 's/%3[Dd]/=/'            )
# --- 2.joint all lines with "&" (note: string for giving to the API)
apip_get=$(printf '%s' "${apip_enc}" |
           tr '\n' '&'               |
           grep ^                    |
           sed 's/^./?&/'            )

# === Check whether my bearer token is available or not ==============
check_my_bearer_token_and_print || exit $?

# === Access to the endpoint =========================================
# --- 1.connect and get a response
apires=$(echo "Authorization: Bearer $MY_bearer"            |
         while read -r oa_hdr; do                           #
           if   [ -n "${CMD_WGET:-}" ]; then                #
             [ -n "$timeout" ] && {                         #
               timeout="--connect-timeout=$timeout"         #
             }                                              #
             if type gunzip >/dev/null 2>&1; then           #
               comp='--header=Accept-Encoding: gzip'        #
             else                                           #
               comp=''                                      #
             fi                                             #
             "$CMD_WGET" ${no_cert_wget:-} -q -O -          \
                         --header="$oa_hdr"                 \
                         $timeout "$comp"                   \
                         "$API_endpt$apip_get"            | #
             if [ -n "$comp" ]; then gunzip; else cat; fi   #
           elif [ -n "${CMD_CURL:-}" ]; then                #
             [ -n "$timeout" ] && {                         #
               timeout="--connect-timeout $timeout"         #
             }                                              #
             "$CMD_CURL" ${no_cert_curl:-} -s               \
                         $timeout ${curl_comp_opt:-}        \
                         -H "$oa_hdr"                       \
                         "$API_endpt$apip_get"              #
           fi                                               #
         done                                               |
         if [ $(echo '1\n1' | tr '\n' '_') = '1_1_' ]; then #
           grep ^ | sed 's/\\/\\\\/g'                       #
         else                                               #
           cat                                              #
         fi                                                 )
# --- 2.exit immediately if it failed to access
case $? in [!0]*) error_exit 1 'Failed to access API';; esac

# === Parse the response =============================================
# --- 1.extract the required parameters from the response (written in JSON)   #
echo "$apires"                                                                |
if [ -n "$rawoutputfile" ]; then tee "$rawoutputfile"; else cat; fi           |
parsrj.sh 2>/dev/null                                                         |
unescj.sh -n 2>/dev/null                                                      |
tr -d '\000\034'                                                              |
sed 's/&amp;/'$(printf '\034')'/g'                                            |
sed 's/&lt;/</g' | sed 's/&gt;/>/g' | tr '\034' '&'                           |
sed 's/^\$\[\([0-9]\{1,\}\)\]\./\1 /'                                         |
awk '                                                                         #
  {                        k=$2;                                            } #
  sub(/^retweeted_status\./,"",k){rtwflg++;if(rtwflg==1){init_param(1);}    } #
  $2=="created_at"        {init_param(2);tm=substr($0,length($1 $2)+3);next;} #
  $2=="id"                {id= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="full_text"         {tx= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="retweet_count"     {nr= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="favorite_count"    {nf= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="retweeted"         {fr= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="favorited"         {ff= substr($0,length($1 $2)+3);print_tw();  next;} #
  $2=="user.name"         {nm= substr($0,length($1 $2)+3);print_tw();  next;} #
  $2=="user.screen_name"  {sn= substr($0,length($1 $2)+3);print_tw();  next;} #
  $2=="user.verified"     {vf=(substr($0,length($1 $2)+3)=="true")?"[v]":"";  #
                                                                       next;} #
  k =="geo"               {ge= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="geo.coordinates[0]"{la= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="geo.coordinates[1]"{lo= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="place"             {pl= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="place.full_name"   {pn= substr($0,length($1 $2)+3);print_tw();  next;} #
  k =="source"            {s = substr($0,length($1 $2)+3);                    #
                           an= s;sub(/<\/a>$/,"",an);sub(/^<a[^>]*>/,"",an);  #
                           au= s;sub(/^.*href="/,"",au);sub(/".*$/,"",au);    #
                                                          print_tw();  next;} #
  k ~/^(entities\.urls|extended_entities\.media)\[[0-9]+\]\.url$/{            #
                           reg_tco_url(k,substr($0,length($1 $2)+3));         #
                           en=1;                                       next;} #
  k ~/^entities\.urls\[[0-9]+\]\.(expanded|display)_url$/{                    #
                           reg_origurl(k,substr($0,length($1 $2)+3));  next;} #
  k ~/^extended_entities\.media\[[0-9]+\]\.media_url_https$/{                 #
                           reg_origurl(k,substr($0,length($1 $2)+3));  next;} #
  function init_param(lv) {tx=""; an=""; au="";                               #
                           nr=""; nf=""; fr=""; ff="";                        #
                           ge=""; la=""; lo=""; pl=""; pn="";                 #
                           split("",eu); split("",du); split("",mu);          #
                           split("",tc); en=0;                                #
                           if (lv<2) {return;}                                #
                           tm=""; id=""; nm=""; sn=""; vf=""; rtwflg="";    } #
  function print_tw( r,f) {                                                   #
    if (tm=="") {return;}                                                     #
    if (id=="") {return;}                                                     #
    if (tx=="") {return;}                                                     #
    if (nr=="") {return;}                                                     #
    if (nf=="") {return;}                                                     #
    if (fr=="") {return;}                                                     #
    if (ff=="") {return;}                                                     #
    if (nm=="") {return;}                                                     #
    if (sn=="") {return;}                                                     #
    if (((la=="")||(lo==""))&&(ge!="null")) {return;}                         #
    if ((pn=="")&&(pl!="null"))             {return;}                         #
    if (an=="") {return;}                                                     #
    if (au=="") {return;}                                                     #
    if (rtwflg>0){tx=" RT " tx;}                                              #
    r = (fr=="true") ? "RET" : "ret";                                         #
    f = (ff=="true") ? "FAV" : "fav";                                         #
    if (en>0) {replace_url();}                                                #
    printf("%s\n"                                   ,tm       );              #
    printf("- %s (@%s)%s\n"                         ,nm,sn,vf );              #
    printf("- %s\n"                                 ,tx       );              #
    printf("- %s:%d %s:%d\n"                        ,r,nr,f,nf);              #
    s = (pl=="null")?"-":pn;                                                  #
    s = (ge=="null")?s:sprintf("%s (%s,%s)",s,la,lo);                         #
    print "-",s;                                                              #
    printf("- %s (%s)\n"                            ,an,au    );              #
    printf("- https://twitter.com/i/web/status/%s\n",id       );              #
    init_param(2);                                                          } #
  function reg_tco_url(k,v ,p,i) {                                            #
    k=substr(k,1,length(k)-5);                                                #
    p=index(k,"entities.urls["          );                                    #
    if (p>0) {i="U" substr(k,p+14);                                           #
              if (v in tc) {tc[v]=tc[v] " " i;} else {tc[v]=i;}               #
              return;                                          }              #
    p=index(k,"extended_entities.media[");                                    #
    if (p>0) {i="M" substr(k,p+24);                                           #
              if (v in tc) {tc[v]=tc[v] " " i;} else {tc[v]=i;}               #
              return;                                          }            } #
  function reg_origurl(k,v ,p,i) {                                            #
    if        (sub(/\]\.media_url_https$/,"",k)) {                            #
      p=index(k,"extended_entities.media[");                                  #
      if (p==0) {return;}                                                     #
      i="M" substr(k,p+24);                                                   #
      if (i in mu) {mu[i]=mu[i] " " v;} else {mu[i]=v;}                       #
    } else if (sub(/\]\.expanded_url$/   ,"",k)) {                            #
      p=index(k,"entities.urls["          );                                  #
      if (p==0) {return;}                                                     #
      i="U" substr(k,p+14);                                                   #
      if (i in eu) {eu[i]=eu[i] " " v;} else {eu[i]=v;}                       #
    } else if (sub(/\]\.display_url$/    ,"",k)) {                            #
      p=index(k,"entities.urls["          );                                  #
      if (p==0) {return;}                                                     #
      i="U" substr(k,p+14);                                                   #
      if (i in du) {du[i]=du[i] " " v;} else {du[i]=v;}                       #
    }                                                                       } #
  function replace_url( tx0,u,i,p,a,b,c,d) {                                  #
    tx0=tx; tx=""; i=0;                                                       #
    while (match(tx0,/https?:\/\/t\.co\/[A-Za-z0-9_]+/)) {                    #
      u=substr(tx0,RSTART,RLENGTH);                                           #
      if (!(u in tc)) {tx =tx substr(tx0,1,RSTART+RLENGTH-1);                 #
                       tx0=   substr(tx0,  RSTART+RLENGTH  );continue;}       #
      tx=tx substr(tx0,1,RSTART-1); tx0=substr(tx0,RSTART+RLENGTH);           #
      a="";                                                                   #
      b=tc[u];                                                                #
      while (match(b,/[UM][0-9]+/)) {                                         #
        a=a substr(b,     1,RSTART-1);                                        #
        i=  substr(b,RSTART,RLENGTH );                                        #
        b=  substr(b,RSTART+RLENGTH );                                        #
        if        (i in eu) {                                                 #
          c=eu[i];                                                            #
          if (i in du) {                                                      #
            d=du[i];sub(/^https?:\/\//,"",d);sub(/\/.*$/,"",d);               #
            if ((! index(d,"…")) && match(c,/:\/\/[^\/]+/)) {                #
              c=substr(c,1,RSTART+2) d substr(c,RSTART+RLENGTH);              #
            }                                                                 #
          }                                                                   #
        } else if (i in mu) {                                                 #
          c=mu[i];                                                            #
        } else              {                                                 #
          c=u;                                                                #
        }                                                                     #
        a=a c;                                                                #
      }                                                                       #
      tx=tx a b;                                                              #
    }                                                                         #
    tx=tx tx0;                                                             }' |
# --- 2.convert date string into "YYYY/MM/DD hh:mm:ss"                        #
awk 'BEGIN {m["Jan"]="01"; m["Feb"]="02"; m["Mar"]="03"; m["Apr"]="04";       #
            m["May"]="05"; m["Jun"]="06"; m["Jul"]="07"; m["Aug"]="08";       #
            m["Sep"]="09"; m["Oct"]="10"; m["Nov"]="11"; m["Dec"]="12";    }  #
     /^[A-Z]/{t=$4; gsub(/:/,"",t);                                           #
              d=substr($5,1,1) (substr($5,2,2)*3600+substr($5,4)*60); d*=1;   #
              printf("%04d%02d%02d%s\034%s\n",$6,m[$2],$3,t,d);       next;}  #
     {        print;                                                       }' |
tr ' \t\034' '\006\025 '                                                      |
awk 'BEGIN   {ORS="";             }                                           #
     /^[0-9]/{print "\n" $0; next;}                                           #
             {print "",  $0; next;}                                           #
     END     {print "\n"   ;      }'                                          |
tail -n +2                                                                    |
# 1:UTC-time(14dgt) 2:delta(local-UTC) 3:screenname 4:tweet 5:ret&fav 6:place #
# 7:App-name 8:URL                                                            #
TZ=UTC+0 calclock 1                                                           |
# 1:UTC-time(14dgt) 2:UNIX-time 3:delta(local-UTC) 4:screenname 5:tweet       #
# 6:ret&fav 7:place 8:App-name 9:URL                                          #
awk '{print $2-$3,$4,$5,$6,$7,$8,$9;}'                                        |
# 1:UNIX-time(adjusted) 2:screenname 3:tweet 4:ret&fav 5:place 6:URL          #
# 7:App-name                                                                  #
calclock -r 1                                                                 |
# 1:UNIX-time(adjusted) 2:localtime 3:screenname 4:tweet 5:ret&fav 6:place    #
# 7:URL 8:App-name                                                            #
self 2/8                                                                      |
# 1:local-time 2:screenname 3:tweet 4:ret&fav 5:place 6:URL 7:App-name        #
tr ' \006\025' '\n \t'                                                        |
awk 'BEGIN   {fmt="%04d/%02d/%02d %02d:%02d:%02d\n";            }             #
     /^[0-9]/{gsub(/[0-9][0-9]/,"& "); sub(/ /,""); split($0,t);              #
              printf(fmt,t[1],t[2],t[3],t[4],t[5],t[6]);                      #
              next;                                             }             #
     {        print;}                                            '            |
# --- 3.delete all the 7n+5,7n+6 lines if verbose option is not set           #
case $verbose in                                                              #
  0) awk 'BEGIN{                                                              #
       while(getline l){n=NR%7;if(n==5||n==6){continue;}else{print l;}}       #
     }'                                                                ;;     #
  1) cat                                                               ;;     #
esac                                                                          |
# --- 4.regard as an error if no line was outputed                            #
awk '{print;} END{exit 1-(NR>0);}'

# === Print error message if some error occured ======================
case $? in [!0]*)
  err=$(echo "$apires"                                              |
        parsrj.sh 2>/dev/null                                       |
        awk 'BEGIN          {errcode=-1;                          } #
             $1~/\.code$/   {errcode=$2;                          } #
             $1~/\.message$/{errmsg =$0;sub(/^.[^ ]* /,"",errmsg);} #
             $1~/\.error$/  {errmsg =$0;sub(/^.[^ ]* /,"",errmsg);} #
             END            {print errcode, errmsg;               }')
  [ -z "${err#* }" ] || { error_exit 1 "API error(${err%% *}): ${err#* }"; }
;; esac


######################################################################
# Finish
######################################################################

exit 0
