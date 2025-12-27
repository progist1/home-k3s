```sh
sudo apt update && sudo apt upgrade
sudo apt install -y nano nfs-common iptables dnsutils iputils-ping net-tools traceroute mtr lsof
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo mv /etc/resolv.conf /etc/resolv.conf_
echo "nameserver 9.9.9.9" | sudo tee /etc/resolv.conf
curl -sfL https://get.k3s.io | K3S_URL="https://...:6443" K3S_TOKEN="..." sh -
```

`K3S_TOKEN`: `sudo cat /var/lib/rancher/k3s/server/node-token`
