требуется hostnetwork.
в настройках 
PostUp: iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ens3 -j MASQUERADE; iptables -A INPUT -p udp -m udp --dport 51820 -j ACCEPT; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT;
PostDown: iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o ens3 -j MASQUERADE; iptables -D INPUT -p udp -m udp --dport 51820 -j ACCEPT; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT;

ens3 → нодовский внешний интерфейс
можно без hostNetwork, но тогда не будет доступа из домашней сети к клиентам.