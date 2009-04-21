#!/bin/bash


apt-get update;
apt-get upgrade;
apt-get clean


apt-get install apache2-mpm-prefork libapache2-mod-rpaf
apt-get install mysql-server mysql-client
apt-get install erlang-nox


apt-get install unzip zip rsync libopenssl-ruby libhmac-ruby

(cd /tmp;
wget http://www.rabbitmq.com/releases/rabbitmq-server/v1.5.4/rabbitmq-server_1.5.4-1_all.deb;
dpkg -i rabbitmq-server_1.5.4-1_all.deb;
)


adduser --system --disabled-password --disabled-login wakame wakame

update-rc.d -f apache2 remove
update-rc.d -f mysql remove
update-rc.d -f mysql-ndb remove
update-rc.d -f mysql-ndb-mgm remove
update-rc.d -f rabbitmq-server remove

cat <<EOF > /usr/local/bin/passenger_ruby.sh
#!/bin/sh
export GEM_PATH="/usr/local/gems"
exec /usr/bin/ruby $@
EOF
chmod 755 /usr/local/bin/passenger_ruby.sh

