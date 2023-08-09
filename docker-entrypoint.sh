#!/bin/bash
set -euo pipefail

chown root:root /home
chmod 755 /home

cp /tempmounts/munge.key /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 600 /etc/munge/munge.key

if [ "$1" = "slurmdbd" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Starting the Slurm Database Daemon (slurmdbd) ..."

    cp /tempmounts/slurmdbd.conf /etc/slurm/slurmdbd.conf
    echo "StoragePass=${StoragePass}" >> /etc/slurm/slurmdbd.conf
    chown slurm:slurm /etc/slurm/slurmdbd.conf
    chmod 600 /etc/slurm/slurmdbd.conf
    {
        . /etc/slurm/slurmdbd.conf
        until echo "SELECT 1" | mysql -h $StorageHost -u$StorageUser -p$StoragePass 2>&1 > /dev/null
        do
            echo "-- Waiting for database to become active ..."
            sleep 2
        done
    }
    echo "-- Database is now active ..."

    exec gosu slurm /usr/sbin/slurmdbd -Dvvv
fi

if [ "$1" = "slurmctld" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Waiting for slurmdbd to become active before starting slurmctld ..."

    until 2>/dev/null >/dev/tcp/slurmdbd/6819
    do
        echo "-- slurmdbd is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmdbd is now active ..."

    echo "---> Setting permissions for state directory ..."
    chown slurm:slurm /var/spool/slurmctld

    echo "---> Starting the Slurm Controller Daemon (slurmctld) ..."
    if /usr/sbin/slurmctld -V | grep -q '17.02' ; then
        exec gosu slurm /usr/sbin/slurmctld -Dvvv
    else
        exec gosu slurm /usr/sbin/slurmctld -i -Dvvv
    fi
fi

if [ "$1" = "slurmd" ]
then
    echo "---> Set shell resource limits ..."
    ulimit -l unlimited
    ulimit -s unlimited
    ulimit -n 131072
    ulimit -a

    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Waiting for slurmctld to become active before starting slurmd..."

    until 2>/dev/null >/dev/tcp/slurmctld-0/6817
    do
        echo "-- slurmctld is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmctld is now active ..."

    echo "---> Starting the Slurm Node Daemon (slurmd) ..."
    exec /usr/sbin/slurmd -F -Dvvv
fi

if [ "$1" = "login" ]
then
    
    echo "---> Setting up ssh for user"
    mkdir -p /home/rocky/.ssh
    cp tempmounts/authorized_keys /home/rocky/.ssh/authorized_keys

    if [ -f /home/rocky/.ssh/id_rsa.pub ]; then
        echo "ssh keys already found"
    else
            ssh-keygen -t rsa -f /home/rocky/.ssh/id_rsa -N ""
    fi

    echo "---> Setting permissions for user home directories"
    cd /home
    for DIR in */;
    do USER_TO_SET=$( echo $DIR | sed "s/.$//" ) && (chown -R $USER_TO_SET:$USER_TO_SET $USER_TO_SET || echo "Failed to take ownership of $USER_TO_SET") \
     && (chmod 700 /home/$USER_TO_SET/.ssh || echo "Couldn't set permissions for .ssh directory for $USER_TO_SET") \
     && (chmod 600 /home/$USER_TO_SET/.ssh/authorized_keys || echo "Couldn't set permissions for .ssh/authorized_keys for $USER_TO_SET");
    done
    echo "---> Complete"
    echo "Starting sshd"
    cp /tempmounts/etc/ssh/* /etc/ssh/
    chmod 600 /etc/ssh/ssh_host_dsa_key
    chmod 600 /etc/ssh/ssh_host_ecdsa_key
    chmod 600 /etc/ssh/ssh_host_ed25519_key
    chmod 600 /etc/ssh/ssh_host_rsa_key
    /usr/sbin/sshd

    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged
    echo "---> MUNGE Complete"

    echo "---> Setting up self ssh capabilities for OOD"
    ssh-keyscan localhost > /etc/ssh/ssh_known_hosts
    echo "" >> /home/rocky/.ssh/authorized_keys #Adding newline to avoid breaking authorized_keys file
    cat /home/rocky/.ssh/id_rsa.pub >> /home/rocky/.ssh/authorized_keys

    echo "---> Setting up Apache Server"

    mkdir --parents /etc/ood/config/apps/shell
    env > /etc/ood/config/apps/shell/env

    /usr/libexec/httpd-ssl-gencerts
    /opt/ood/ood-portal-generator/sbin/update_ood_portal
    mkdir --parents /opt/rh/httpd24/root/etc/httpd/

    /usr/bin/htdbm -cb /opt/rh/httpd24/root/etc/httpd/.htpasswd.dbm rocky $ROCKY_OOD_PASS

    echo "---> Setting up Jupyter App"
    mkdir --parents /var/www/ood/apps/sys/jupyter
    git clone $JUPYTER_REPO --branch $JUPYTER_TAG /var/www/ood/apps/sys/jupyter

    echo "---> Starting Apache server"
    /usr/sbin/httpd -k start -X -e debug
fi

if [ "$1" = "check-queue-hook" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged
    echo "---> MUNGE Complete"

    RUNNING_JOBS=$(squeue --states=RUNNING,COMPLETING,CONFIGURING,RESIZING,SIGNALING,STAGE_OUT,STOPPED,SUSPENDED --noheader --array | wc --lines)

    if [[ $RUNNING_JOBS -eq 0 ]]
    then
            exit 0
    else
            exit 1
    fi
fi

exec "$@"
