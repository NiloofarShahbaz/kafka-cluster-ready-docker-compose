#!/usr/bin/env bash

set -e

VALIDITY_IN_DAYS=365
DEFAULT_TRUSTSTORE_FILENAME="kafka.truststore.jks"
TRUSTSTORE_WORKING_DIRECTORY="truststore"
KEYSTORE_WORKING_DIRECTORY="keystore"
CA_CERT_FILE="ca-cert"
KEYSTORE_SIGN_REQUEST="cert-file"
KEYSTORE_SIGN_REQUEST_SRL="ca-cert.srl"
KEYSTORE_SIGNED_CERT="cert-signed"

PASSWORD="test1234"
CN="kafka-ca"
OU="Backend"
O="Sensifai"
L="Tehran"
C="IR"

function file_exists_and_exit() {
  echo "'$1' cannot exist. Move or delete it before"
  echo "re-running this script."
  exit 1
}

if [ -e "$KEYSTORE_WORKING_DIRECTORY" ]; then
  file_exists_and_exit $KEYSTORE_WORKING_DIRECTORY
fi

if [ -e "$CA_CERT_FILE" ]; then
  file_exists_and_exit $CA_CERT_FILE
fi

if [ -e "$KEYSTORE_SIGN_REQUEST" ]; then
  file_exists_and_exit $KEYSTORE_SIGN_REQUEST
fi

if [ -e "$KEYSTORE_SIGN_REQUEST_SRL" ]; then
  file_exists_and_exit $KEYSTORE_SIGN_REQUEST_SRL
fi

if [ -e "$KEYSTORE_SIGNED_CERT" ]; then
  file_exists_and_exit $KEYSTORE_SIGNED_CERT
fi

echo
echo "Welcome to the Kafka SSL keystore and truststore generator script."

echo
echo "First, do you need to generate a trust store and associated private key,"
echo "or do you already have a trust store file and private key?"
echo
echo -n "Do you need to generate a trust store and associated private key? [yn] "
read generate_trust_store

trust_store_file=""
trust_store_private_key_file=""

if [ "$generate_trust_store" == "y" ]; then
  if [ -e "$TRUSTSTORE_WORKING_DIRECTORY" ]; then
    file_exists_and_exit $TRUSTSTORE_WORKING_DIRECTORY
  fi

  mkdir $TRUSTSTORE_WORKING_DIRECTORY
  echo
  echo "OK, we'll generate a trust store and associated private key."
  echo
  echo "First, the private key."

  openssl req -new -x509 \
	  -keyout $TRUSTSTORE_WORKING_DIRECTORY/ca-key \
	  -out $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE \
	  -days $VALIDITY_IN_DAYS \
	  -subj "/CN=$CN/OU=$OU/O=$O/L=$L/C=$C" \
	  -passin pass:$PASSWORD \
	  -passout pass:$PASSWORD

  trust_store_private_key_file="$TRUSTSTORE_WORKING_DIRECTORY/ca-key"

  echo
  echo "Two files were created:"
  echo " - $TRUSTSTORE_WORKING_DIRECTORY/ca-key -- the private key used later to"
  echo "   sign certificates"
  echo " - $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE -- the certificate that will be"
  echo "   stored in the trust store in a moment and serve as the certificate"
  echo "   authority (CA). Once this certificate has been stored in the trust"
  echo "   store, it will be deleted. It can be retrieved from the trust store via:"
  echo "   $ keytool -keystore <trust-store-file> -export -alias CARoot -rfc"

  echo
  echo "Now the trust store will be generated from the certificate."

  keytool -noprompt \
	  -keystore $TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILENAME \
	  -alias CARoot \
	  -import -file $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE \
	  -storepass $PASSWORD \
	  -keypass $PASSWORD
    

  trust_store_file="$TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILENAME"

  echo
  echo "$TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILENAME was created."

else
  echo
  echo -n "Enter the path of the trust store file. "
  read -e trust_store_file

  if ! [ -f $trust_store_file ]; then
    echo "$trust_store_file isn't a file. Exiting."
    exit 1
  fi

  echo -n "Enter the path of the trust store's private key. "
  read -e trust_store_private_key_file

  if ! [ -f $trust_store_private_key_file ]; then
    echo "$trust_store_private_key_file isn't a file. Exiting."
    exit 1
  fi
fi

echo
echo "Continuing with:"
echo " - trust store file:        $trust_store_file"
echo " - trust store private key: $trust_store_private_key_file"

mkdir $KEYSTORE_WORKING_DIRECTORY

echo
echo "Now, a keystore will be generated. Each broker and logical client needs its own"
echo "keystore. This script will create only one keystore. Run this script multiple"
echo "times for multiple keystores."
echo -n "Please enter the name of the broker/client name: "
read hostname

KEYSTORE_FILENAME="$hostname.keystore.jks"


# To learn more about CNs and FQDNs, read:
# https://docs.oracle.com/javase/7/docs/api/javax/net/ssl/X509ExtendedTrustManager.html

keytool -noprompt -genkey \
	-keystore $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_FILENAME \
	-alias localhost \
	-validity $VALIDITY_IN_DAYS \
	-keyalg RSA \
	-storepass $PASSWORD \
	-keypass $PASSWORD \
	-dname "CN=$hostname,OU=$OU,O=$O,L=$L,C=$C" \
	-ext "SAN=dns:$hostname"

echo
echo "'$KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_FILENAME' now contains a key pair and a"
echo "self-signed certificate. Again, this keystore can only be used for one broker or"
echo "one logical client. Other brokers or clients need to generate their own keystores."

echo
echo "Now a certificate signing request will be made to the keystore."

keytool -noprompt -alias localhost\
	-keystore $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_FILENAME \
	-certreq -file $KEYSTORE_SIGN_REQUEST \
	-keypass $PASSWORD \
	-storepass $PASSWORD \
	-ext "SAN=dns:$hostname"

echo
echo "Now the trust store's private key (CA) will sign the keystore's certificate."

openssl x509 -req \
	-CA $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE \
	-CAkey $trust_store_private_key_file \
	-in $KEYSTORE_SIGN_REQUEST \
	-out $KEYSTORE_SIGNED_CERT \
	-days $VALIDITY_IN_DAYS \
	-CAcreateserial \
	-passin pass:$PASSWORD \
	-passin pass:$PASSWORD \
	-extfile <(cat <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = req_ext

[req_distinguished_name]
countryName = IR
localityName = Tehran
organizationName = Sensifai
commonName = kafka-ca

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $hostname
EOF
)
# creates $KEYSTORE_SIGN_REQUEST_SRL which is never used or needed.

echo
echo "Now the CA will be imported into the keystore."

keytool -alias CARoot -noprompt \
	-keystore $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_FILENAME \
	-import -file $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE \
	-keypass $PASSWORD \
	-storepass $PASSWORD 

echo
echo "Now the keystore's signed certificate will be imported back into the keystore."

keytool -alias localhost \
	-noprompt -import \
	-keystore $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_FILENAME \
	-file $KEYSTORE_SIGNED_CERT \
	-keypass $PASSWORD \
	-storepass $PASSWORD \
	-ext "SAN=dns:$hostname"

echo
echo "All done!"
echo
echo "Delete intermediate files? They are:"
echo " - '$KEYSTORE_SIGN_REQUEST_SRL': CA serial number"
echo " - '$KEYSTORE_SIGN_REQUEST': the keystore's certificate signing request"
echo "   (that was fulfilled)"
echo " - '$KEYSTORE_SIGNED_CERT': the keystore's certificate, signed by the CA, and stored back"
echo "    into the keystore"
echo -n "Delete? [yn] "
read delete_intermediate_files

if [ "$delete_intermediate_files" == "y" ]; then
  rm $TRUSTSTORE_WORKING_DIRECTORY/$KEYSTORE_SIGN_REQUEST_SRL
  rm $KEYSTORE_SIGN_REQUEST
  rm $KEYSTORE_SIGNED_CERT
fi

#echo "Now converting jks keys to pem..."
#echo "generating kafka.truststore.pem by renaming ca-cert file to kafka.truststore.pem"
#mv $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE  $TRUSTSTORE_WORKING_DIRECTORY/kafka.truststore.pem


