требуется hostnetwork.
в настройках 
PostUp: iptables -A INPUT -p udp --dport 51820 -j ACCEPT;    iptables -A FORWARD -i wg0 -o cni0 -j ACCEPT;    iptables -A FORWARD -i cni0 -o wg0 -j ACCEPT;    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ens3 -j MASQUERADE;  iptables -t nat -A POSTROUTING -s 10.3.0.0/24 -o ens3 -j MASQUERADE; 
PostDown: iptables -D FORWARD -i wg0 -o cni0 -j ACCEPT;   iptables -D FORWARD -i cni0 -o wg0 -j ACCEPT;   iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o ens3 -j MASQUERADE;  iptables -t nat -D POSTROUTING -s 10.3.0.0/24 -o ens3 -j MASQUERADE;

ens3 → нодовский внешний интерфейс
можно без hostNetwork, но тогда не будет доступа из домашней сети к клиентам.