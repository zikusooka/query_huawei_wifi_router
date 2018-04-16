#!/bin/sh
# This script queries a Huawei LTE WiFi router (MiFi) to get detailed information such
# as signal strength, battery status, remaining data balance etc.
#
# Copyright (C) 2018-2019 Joseph Zikusooka.
#
# Find me on twitter @jzikusooka or email josephzik AT gmai.com

#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.


# Variables
CURL_CMD="/usr/bin/curl"
CURL_OPTS="-L -s -S -m 60 -A 'Mozilla/5.0' -k -b MIFI_COOKIE_JAR -c MIFI_COOKIE_JAR"
MIFI_IP_ADDRESS=$1
MIFI_LOGIN_ADMIN_USER="$2"
MIFI_LOGIN_ADMIN_PASSWORD="$3"
MIFI_LOGIN_ADMIN_PASSWORD_BASE64=$(printf "$(printf "$MIFI_LOGIN_ADMIN_PASSWORD" | sha256sum |  cut -d ' ' -f 1)" | base64 -w 0)
MIFI_ACTION=$4
MIFI_LOGIN_OUTPUT_FILE=/tmp/router_login
HTTP_BROWSER_USERAGENT="Mozilla/5.0"
HTTP_BROWSER_COMMAND="$CURL_CMD $CURL_OPTS"
SMS_MESSAGE_RAW_OUTPUT_FILE=/tmp/router_sms_message
HOSTS_CONNECTED_OUTPUT_FILE=/tmp/router_wifi_connected_hosts



###############
#  FUNCTIONS  #
###############

# Usage
usage () {
if [[ "x$MIFI_IP_ADDRESS" = "x" || "x$MIFI_LOGIN_ADMIN_USER" = "x" || "x$MIFI_LOGIN_ADMIN_PASSWORD" = "x" ]];
then
clear
cat <<EOT
Usage: ./$(basename $0) [IP_ADDRESS] [LOGIN_USER] [LOGIN_PASSWORD][TASK (Optional)]

  e.g. ./$(basename $0) 192.168.8.1 admin secret info


Tasks
-----
info_all
reboot
sms_read
sms_send [NUMBER] [MESSAGE]

EOT
exit
fi
}

# CLI Calculator
calc(){ awk "BEGIN{ print $* }" ;}

server_session_token_info () {
HTTP_BROWSER_URL=http://$MIFI_IP_ADDRESS
MIFI_LOGIN_SERVER_COOKIE=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/webserver/SesTokInfo | grep -oP "(?<=<SesInfo>).+?(?=</SesInfo>)")
MIFI_LOGIN_SERVER_TOKEN=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/webserver/SesTokInfo | grep -oP "(?<=<TokInfo>).+?(?=</TokInfo>)")
MIFI_ADMIN_USER_PASSWORD_TOKEN="${MIFI_LOGIN_ADMIN_USER}${MIFI_LOGIN_ADMIN_PASSWORD}${MIFI_LOGIN_SERVER_TOKEN}" 
MIFI_LOGIN_SERVER_PASSWORD_BASE64="$(printf "$(printf "${MIFI_ADMIN_USER_PASSWORD_TOKEN}" | sha256sum | cut -d ' ' -f 1)" | base64 -w 0)"
}

# Login
login () {
server_session_token_info
#
# Remove any existing login output file
[[ -e $MIFI_LOGIN_OUTPUT_FILE ]] && rm -f $MIFI_LOGIN_OUTPUT_FILE
# Connect and Login
$HTTP_BROWSER_COMMAND -o $MIFI_LOGIN_OUTPUT_FILE $HTTP_BROWSER_URL/api/user/login \
	-H "__RequestVerificationToken: $MIFI_LOGIN_SERVER_TOKEN" \
	-H "Cookie: $MIFI_LOGIN_SERVER_COOKIE" \
	-H "X-Requested-With: XMLHttpRequest" \
	-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
	-d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Username>$MIFI_LOGIN_ADMIN_USER</Username><Password>$(printf "$(printf "$MIFI_LOGIN_ADMIN_USER$MIFI_LOGIN_ADMIN_PASSWORD_BASE64$MIFI_LOGIN_SERVER_TOKEN" | sha256sum | cut -d ' ' -f 1)" | base64 -w 0)</Password><password_type>4</password_type></request>"
# Get login response
LOGIN_RESPONSE=$(grep -oP "(?<=<response>).+?(?=</response>)" $MIFI_LOGIN_OUTPUT_FILE)
if [ "$LOGIN_RESPONSE" = "OK" ];
then
echo "Logged in to your WiFi router"

else
cat <<EOT
Error: Could not Log in to your Wifi router.  Possible reasons include:

a) The password you used '$MIFI_LOGIN_ADMIN_PASSWORD' is incorrect
b) The username name you used '$MIFI_LOGIN_ADMIN_USER' is incorrect
c) The IP address of '$MIFI_IP_ADDRESS' is not reachable

EOT
exit 2
fi
}

# Device Info
device_information () {
login
DEVICE_NAME=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/information | grep -oP "(?<=<DeviceName>).+?(?=</DeviceName>)")
DEVICE_SERIAL=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/information | grep -oP "(?<=<SerialNumber>).+?(?=</SerialNumber>)")
DEVICE_IMEI=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/information | grep -oP "(?<=<Imei>).+?(?=</Imei>)")
DEVICE_IMSI=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/information | grep -oP "(?<=<Imsi>).+?(?=</Imsi>)")
DEVICE_MAC1=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/information | grep -oP "(?<=<MacAddress1>).+?(?=</MacAddress1>)")
DEVICE_CLASS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/information | grep -oP "(?<=<Classify>).+?(?=</Classify>)")
DEVICE_ICCID=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/information | grep -oP "(?<=<Iccid>).+?(?=</Iccid>)")
}

# Sim Status
sim_status () {
DEVICE_SIM_LOCK_STATUS_CURRENT=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<simlockStatus>).+?(?=</simlockStatus>)")
if [ "$DEVICE_SIM_LOCK_STATUS_CURRENT" = "0" ];
then
DEVICE_SIM_LOCK_STATUS="Unlocked"
else
DEVICE_SIM_LOCK_STATUS="Locked"
fi
#DEVICE_SIM_STATUS_CURRENT=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<simlockStatus>).+?(?=</simlockStatus>)")
#
# Alternative for Sim state and Lock
#api/monitoring/converged-status
}

# Battery Status
battery_status () {
BATTERY_STATUS_CURRENT=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<BatteryStatus>).+?(?=</BatteryStatus>)")
BATTERY_PERCENT=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<BatteryPercent>).+?(?=</BatteryPercent>)")
# Set Battery status type
if [[ "$BATTERY_STATUS_CURRENT" = "1" ]];
then
BATTERY_STATUS="Charging"
else
BATTERY_STATUS="Not Charging"
fi
}

# WiFi status
wifi_status () {
WIFI_CONNECTION_STATUS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<WifiConnectionStatus>).+?(?=</WifiConnectionStatus>)")
WIFI_CURRENT_USERS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<CurrentWifiUser>).+?(?=</CurrentWifiUser>)")
}

# Devices connected to MiFi
wifi_connected_devices () {
login
# Using hostname
$HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/wlan/host-list | grep -oP "(?<=<HostName>).+?(?=</HostName>)" > $HOSTS_CONNECTED_OUTPUT_FILE 
HOSTS_CONNECTED=$(paste -s -d"," $HOSTS_CONNECTED_OUTPUT_FILE)
#
# Using mac address
#$HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/wlan/host-list | grep -oP "(?<=<MacAddress>).+?(?=</MacAddress>)"
# Using IP address
#$HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/wlan/host-list | grep -oP "(?<=<IpAddress>).+?(?=</IpAddress>)"
}

# Network Provider Info
network_provider_info () {
NETWORK_PROVIDER=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/net/current-plmn | grep -oP "(?<=<FullName>).+?(?=</FullName>)")
MCC_MNC_CODE=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/net/current-plmn | grep -oP "(?<=<Numeric>).+?(?=</Numeric>)")
NETWORK_CONNECTION_STATUS_CURRENT=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<ConnectionStatus>).+?(?=</ConnectionStatus>)")
# Define connection status
case $NETWORK_CONNECTION_STATUS_CURRENT in
7|11|14|37)
NETWORK_CONNECTION_STATUS="Network access not allowed"
;;
12|13)
NETWORK_CONNECTION_STATUS="Connection failed, roaming not allowed"
;;
201)
NETWORK_CONNECTION_STATUS="Connection failed, bandwidth exceeded"
;;
900)
NETWORK_CONNECTION_STATUS="Connecting"
;;
901)
NETWORK_CONNECTION_STATUS="Connected"
;;
902)
NETWORK_CONNECTION_STATUS="Disconnected"
;;
903)
NETWORK_CONNECTION_STATUS="Disconnecting"
;;
904)  
NETWORK_CONNECTION_STATUS="Connection failed or disabled"
;;
*)
NETWORK_CONNECTION_STATUS="Connection failed, the profile is invalid"
;;
esac
}

# Signal Info
signal_info () {
CURRENT_SIGNAL_STRENGTH=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<SignalIcon>).+?(?=</SignalIcon>)")
# Signal bars
case $CURRENT_SIGNAL_STRENGTH in
5)
NUMBER_OF_BARS=$(printf "\u2581\u2582\u2583\u2584\u2585")
;;
4)
NUMBER_OF_BARS=$(printf "\u2581\u2582\u2583\u2584") 
;;
3)
NUMBER_OF_BARS=$(printf "\u2581\u2582\u2583") 
;;
2)
NUMBER_OF_BARS=$(printf "\u2581\u2582") 
;;
1)
NUMBER_OF_BARS=$(printf "\u2581") 
;;
*)
NUMBER_OF_BARS=$(printf "") 
;;
esac
#
MAXIMUM_SIGNAL_STRENGTH=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<maxsignal>).+?(?=</maxsignal>)")
SIGNAL_PERCENT=$(calc "$CURRENT_SIGNAL_STRENGTH/$MAXIMUM_SIGNAL_STRENGTH"*100)%
NETWORK_CELL_ID=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/device/signal | grep -oP "(?<=<cell_id>).+?(?=</cell_id>)")
#
# Current Network Type
CURRENT_NETWORK_TYPE=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<CurrentNetworkType>).+?(?=</CurrentNetworkType>)")
case $CURRENT_NETWORK_TYPE in
0)
NETWORK_TYPE="No Service"
;;
1)
NETWORK_TYPE="GSM"
;;
2)
NETWORK_TYPE="GPRS (2.5G)"
;;
3)
NETWORK_TYPE="EDGE (2.75G)"
;;
4)
NETWORK_TYPE="WCDMA (3G)"
;;
5)
NETWORK_TYPE="HSDPA (3G)"
;;
6)
NETWORK_TYPE="HSUPA (3G)"
;;
7)
NETWORK_TYPE="HSPA (3G)"
;;
8)
NETWORK_TYPE="TD-SCDMA (3G)"
;;
9)
NETWORK_TYPE="HSPA+ (4G)"
;;
10)
NETWORK_TYPE="EV-DO rev. 0"
;;
11)
NETWORK_TYPE="EV-DO rev. A"
;;
12)
NETWORK_TYPE="EV-DO rev. B"
;;
13)
NETWORK_TYPE="1xRTT"
;;
14)
NETWORK_TYPE="UMB"
;;
15)
NETWORK_TYPE="1xEVDV"
;;
16)
NETWORK_TYPE="3xRTT"
;;
17)
NETWORK_TYPE="HSPA+ 64QAM"
;;
18)
NETWORK_TYPE="HSPA+ MIMO"
;;
19)
NETWORK_TYPE="LTE (4G)"
;;
41)
NETWORK_TYPE="UMTS (3G)"
;;
44)
NETWORK_TYPE="HSPA (3G)"
;;
45)
NETWORK_TYPE="HSPA+ (3G)"
;;
46)
NETWORK_TYPE="DC-HSPA+ (3G)"
;;
64)
NETWORK_TYPE="HSPA (3G)"
;;
65)
NETWORK_TYPE="HSPA+ (3G)"
;;
101)
NETWORK_TYPE="LTE (4G)"
;;
esac
}

# WAN IP, Primary, Secondary DNS Addresses
ip_address_info () {
WAN_IP_ADDRESS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<WanIPAddress>).+?(?=</WanIPAddress>)")
PRIMARY_DNS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<PrimaryDns>).+?(?=</PrimaryDns>)")
SECONDARY_DNS=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/status | grep -oP "(?<=<SecondaryDns>).+?(?=</SecondaryDns>)")
}

# Data Balance - Available
data_balance_available () {
DATA_BUNDLE=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/start_date | grep -oP "(?<=<DataLimit>).+?(?=</DataLimit>)")
DATA_START_DAY=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/start_date | grep -oP "(?<=<StartDay>).+?(?=</StartDay>)")
DATA_USED_DOWNLOAD=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/month_statistics | grep -oP "(?<=<CurrentMonthDownload>).+?(?=</CurrentMonthDownload>)")
DATA_USED_UPLOAD=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/month_statistics | grep -oP "(?<=<CurrentMonthUpload>).+?(?=</CurrentMonthUpload>)")
# Data Limit in Bytes
if test $(echo $DATA_BUNDLE | grep -i GB);
then
DATA_LIMIT=$(calc $(echo "$DATA_BUNDLE" | sed "s/GB//")*1073741824)

elif test $(echo $DATA_BUNDLE | grep -i MB);
then
DATA_LIMIT=$(calc $(echo "$DATA_BUNDLE" | sed "s/MB//")*1048576)

elif test $(echo $DATA_BUNDLE | grep -i KB);
then
DATA_LIMIT=$(calc $(echo "$DATA_BUNDLE" | sed "s/KB//")*1024)
fi
# Data left
DATA_USED=$(calc $DATA_USED_DOWNLOAD+$DATA_USED_UPLOAD)
DATA_REMAINING=$(calc $DATA_LIMIT-$DATA_USED)

DATA_REMAINING_GB=$(calc $DATA_REMAINING/1073741824 | xargs printf '%.2f')
DATA_REMAINING_MB=$(calc $DATA_REMAINING/1048576 | xargs printf '%.0f')
DATA_REMAINING_PERCENT=$(calc "$DATA_REMAINING/$DATA_LIMIT*100" | xargs printf '%.1f')
}

# SMS - Unread messages
sms_unread_count () {
SMS_COUNT_UNREAD=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/monitoring/check-notifications | grep -oP "(?<=<UnreadMessage>).+?(?=</UnreadMessage>)")
}

sms_count_local_inbox () {
login
SMS_COUNT_LOCAL_INBOX_UNREAD=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/sms/sms-count | grep -oP "(?<=<LocalUnread>).+?(?=</LocalUnread>)")
SMS_COUNT_LOCAL_INBOX_ALL=$($HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/sms/sms-count | grep -oP "(?<=<LocalInbox>).+?(?=</LocalInbox>)")
}

# SMS - Read 1 SMS message 
read_sms_message_one () {
SMS_MESSAGE_COUNT=1
login
server_session_token_info
#
$HTTP_BROWSER_COMMAND -o $SMS_MESSAGE_RAW_OUTPUT_FILE $HTTP_BROWSER_URL/api/sms/sms-list \
	-H "__RequestVerificationToken: $MIFI_LOGIN_SERVER_TOKEN" \
	-H "Cookie: $MIFI_LOGIN_SERVER_COOKIE" \
	-H "X-Requested-With: XMLHttpRequest" \
	-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
	-d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><PageIndex>1</PageIndex><ReadCount>$SMS_MESSAGE_COUNT</ReadCount><BoxType>1</BoxType><SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>0</UnreadPreferred></request>"
# Extract SMS message
SMS_MESSAGE_INDEX=$(grep -oP "(?<=<Index>).+?(?=</Index>)" $SMS_MESSAGE_RAW_OUTPUT_FILE)
SMS_MESSAGE_DATE=$(grep -oP "(?<=<Date>).+?(?=</Date>)" $SMS_MESSAGE_RAW_OUTPUT_FILE)
SMS_MESSAGE_FROM=$(grep -oP "(?<=<Phone>).+?(?=</Phone>)" $SMS_MESSAGE_RAW_OUTPUT_FILE)
SMS_MESSAGE_BODY=$(grep -oP "(?<=<Content>).+?(?=</Content>)" $SMS_MESSAGE_RAW_OUTPUT_FILE)
# Print message
clear
cat <<EOT
Index:		$SMS_MESSAGE_INDEX
Date:		$SMS_MESSAGE_DATE
From:		$SMS_MESSAGE_FROM
Body:		$SMS_MESSAGE_BODY
EOT

# Set SMS message to already-read status
login
server_session_token_info
$HTTP_BROWSER_COMMAND -o /dev/null $HTTP_BROWSER_URL/api/sms/set-read \
	-H "__RequestVerificationToken: $MIFI_LOGIN_SERVER_TOKEN" \
	-H "Cookie: $MIFI_LOGIN_SERVER_COOKIE" \
	-H "X-Requested-With: XMLHttpRequest" \
	-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
	-d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Index>$SMS_MESSAGE_INDEX</Index></request>"
}

# SMS - Send message 
send_sms_message () {
SMS_DATE_NOW=$(date +'%Y-%m-%d %T')
SMS_PHONE_RECIPIENT=$1
SMS_TEXT="$2"
SMS_LENGTH=${#SMS_TEXT}
# Print recipient number and message
cat <<EOF
Sending the following message to $SMS_PHONE_RECIPIENT: $SMS_TEXT

EOF
#
login
server_session_token_info
#
$HTTP_BROWSER_COMMAND $HTTP_BROWSER_URL/api/sms/send-sms \
	-H "__RequestVerificationToken: $MIFI_LOGIN_SERVER_TOKEN" \
	-H "Cookie: $MIFI_LOGIN_SERVER_COOKIE" \
	-H "X-Requested-With: XMLHttpRequest" \
	-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
	-d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Index>-1</Index><Phones><Phone>$SMS_PHONE_RECIPIENT</Phone></Phones><Sca></Sca><Content>$SMS_TEXT</Content><Length>$SMS_LENGTH</Length><Reserved>1</Reserved><Date>$SMS_DATE_NOW</Date></request>"
}

# Reboot
reboot () {
login
server_session_token_info
#
echo "Rebooting MiFi router, please wait ..."
$HTTP_BROWSER_COMMAND -o /dev/null $HTTP_BROWSER_URL/api/device/control \
	-H "__RequestVerificationToken: $MIFI_LOGIN_SERVER_TOKEN" \
	-H "Cookie: $MIFI_LOGIN_SERVER_COOKIE" \
	-H "X-Requested-With: XMLHttpRequest" \
	-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
	-d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Control>1</Control></request>"
}

# All information
all_available_information () {
device_information
sim_status
battery_status
wifi_status
wifi_connected_devices
network_provider_info
signal_info
ip_address_info
data_balance_available
sms_unread_count
sms_count_local_inbox
}



#################
#  MAIN SCRIPT  #
#################

usage

case $MIFI_ACTION in
info_all)
# Query all data
all_available_information
# Print info
clear
cat <<EOT
Device Name:			Huawei $DEVICE_CLASS
Device Model:			$DEVICE_NAME
Device Serial:			$DEVICE_SERIAL
Device Imei:			$DEVICE_IMEI
Device Imsi:			$DEVICE_IMSI
Device Iccid:			$DEVICE_ICCID
Sim Lock Status:		$DEVICE_SIM_LOCK_STATUS

Network Connection status:	$NETWORK_CONNECTION_STATUS
Network Provider:		$NETWORK_PROVIDER ($MCC_MNC_CODE)
Network Type:			$NETWORK_TYPE
Network Signal strength:	$NUMBER_OF_BARS ($SIGNAL_PERCENT)
Network Cell Tower:		$NETWORK_CELL_ID

WAN IP Address:			$WAN_IP_ADDRESS
Primary DNS Address:		$PRIMARY_DNS
Secondary DNS Address:		$SECONDARY_DNS

Data balance remaining:		${DATA_REMAINING_MB}MB / ${DATA_REMAINING_GB}GB 
Data balance remaining:		${DATA_REMAINING_PERCENT}%
Data Started on:		$DATA_START_DAY $(date '+%B %Y')

Battery Charge:			$BATTERY_PERCENT%
Battery Status:			$BATTERY_STATUS

WiFi connected users:		$WIFI_CURRENT_USERS [$HOSTS_CONNECTED]

New SMS Messages (Unread/All):	$SMS_COUNT_UNREAD ($SMS_COUNT_LOCAL_INBOX_UNREAD/$SMS_COUNT_LOCAL_INBOX_ALL)

EOT
;;

sms_read)
read_sms_message_one
;;

sms_send)
send_sms_message "$5" "$6"
;;

reboot)
reboot
;;

*)
echo script=$0
$0 $MIFI_IP_ADDRESS $MIFI_LOGIN_ADMIN_USER $MIFI_LOGIN_ADMIN_PASSWORD info_all
;;

esac




 
