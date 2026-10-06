#!/usr/bin/env python3
"""Заменить одно поле секрета и перезапечатать его в репо, не печатая значения.

    scripts/reseal-secret.py <секрет|ns/секрет> <поле> [значение|-] [опции]

Что делает:
  1. Находит файл SealedSecret в sealed-secrets/ по имени (и namespace) и проверяет живой секрет в кластере
     (только имена ключей: сами значения не читаются, пока это не нужно).
  2. Запечатывает ТОЛЬКО указанное поле через `kubeseal --merge-into`: шифртексты остальных полей не трогаются,
     в git остаётся diff в одно поле.
  3. Проверяет результат (`kubeseal --validate`) и по желанию применяет его в кластер (--apply).

Значение:
  - не передавай его аргументом, если пароль чувствительный (попадёт в историю шелла и список процессов);
    опусти аргумент или поставь `-`: будет скрытый ввод (или чтение из stdin: `pbpaste | ... -`);
  - `--generate [N]` создаёт случайный пароль длиной N (по умолчанию 32), кладёт его в буфер обмена (pbcopy)
    и запечатывает; на экран он не выводится. Вставь его из буфера в Stalwart/приложение.

Если секрета ещё нет в репо, нужен --out <путь>: создастся новый SealedSecret из живого секрета с очищенными
метаданными (потом добавь файл в kustomization.yaml рядом).
"""
import argparse
import base64
import getpass
import json
import os
import secrets as pysecrets
import shutil
import string
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("нужен PyYAML: pip3 install pyyaml")

REPO = Path(__file__).resolve().parent.parent
SEALED_ROOT = REPO / "sealed-secrets"
CTRL_NAME = os.environ.get("SEALED_CONTROLLER_NAME", "sealed-secrets-controller")
CTRL_NS = os.environ.get("SEALED_CONTROLLER_NS", "kube-system")
# метаданные, которые не переносим в новый SealedSecret
SYSTEM_PREFIXES = ("kubectl.kubernetes.io/", "sealedsecrets.bitnami.com/", "kustomize.toolkit.fluxcd.io/")


def die(msg):
    print(f"ошибка: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd, stdin=None, check=True):
    """Запуск без shell; stdin передаётся байтами, чтобы значение не попадало в аргументы."""
    p = subprocess.run(cmd, input=stdin, capture_output=True)
    if check and p.returncode != 0:
        die(f"{' '.join(cmd[:3])}… завершилась с кодом {p.returncode}: {p.stderr.decode(errors='replace').strip()[:400]}")
    return p


def kubeseal_base():
    return ["kubeseal", "--controller-name", CTRL_NAME, "--controller-namespace", CTRL_NS]


def find_sealed(name, namespace):
    """[(path, namespace)] всех SealedSecret с таким именем (и namespace, если задан)."""
    found = []
    for f in sorted(SEALED_ROOT.rglob("*.y*ml")):
        try:
            docs = [d for d in yaml.safe_load_all(f.read_text()) if d]
        except Exception:
            continue
        for d in docs:
            if d.get("kind") != "SealedSecret":
                continue
            m = d.get("metadata", {})
            if m.get("name") == name and (namespace is None or m.get("namespace") == namespace):
                found.append((f, m.get("namespace")))
    return found


def cluster_namespaces(name):
    out = run(["kubectl", "get", "secret", "-A", f"--field-selector=metadata.name={name}", "-o",
               'go-template={{range .items}}{{.metadata.namespace}}{{"\\n"}}{{end}}'], check=False)
    return [x for x in out.stdout.decode().split() if x]


def live_keys(namespace, name):
    """Только имена ключей живого секрета (значения остаются внутри kubectl)."""
    p = run(["kubectl", "-n", namespace, "get", "secret", name, "-o",
             'go-template={{range $k,$v := .data}}{{$k}}{{"\\n"}}{{end}}'], check=False)
    if p.returncode != 0:
        return None
    return p.stdout.decode().split()


def scope_of(sealed_doc):
    a = (sealed_doc.get("metadata", {}).get("annotations") or {})
    if a.get("sealedsecrets.bitnami.com/cluster-wide") == "true":
        return "cluster-wide"
    if a.get("sealedsecrets.bitnami.com/namespace-wide") == "true":
        return "namespace-wide"
    return "strict"


def read_value(args):
    if args.generate is not None:
        alphabet = string.ascii_letters + string.digits
        value = "".join(pysecrets.choice(alphabet) for _ in range(args.generate))
        if shutil.which("pbcopy"):
            subprocess.run(["pbcopy"], input=value.encode(), check=True)
            print(f"сгенерирован пароль ({args.generate} символов), он в буфере обмена (pbcopy), на экран не выводится")
        else:
            die("--generate без pbcopy: некуда безопасно положить пароль (на не-macOS используй пайп: "
                "`head -c 24 /dev/urandom | base64 | tr -d '/+=' | script ... -`)")
        return value
    if args.value not in (None, "-"):
        print("внимание: значение передано аргументом и осядет в истории шелла; лучше опустить его (скрытый ввод)",
              file=sys.stderr)
        return args.value
    if sys.stdin.isatty():
        v1 = getpass.getpass("новое значение (ввод скрыт): ")
        v2 = getpass.getpass("ещё раз: ")
        if v1 != v2:
            die("значения не совпали")
        return v1
    data = sys.stdin.read()
    return data[:-1] if data.endswith("\n") else data


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("secret", help="имя секрета или ns/имя")
    ap.add_argument("field", help="поле (ключ) в секрете")
    ap.add_argument("value", nargs="?", help="новое значение; опусти или `-` для скрытого ввода / stdin")
    ap.add_argument("-n", "--namespace", help="namespace (если имя неоднозначно)")
    ap.add_argument("--generate", nargs="?", const=32, type=int, metavar="N",
                    help="сгенерировать случайный пароль длиной N (по умолчанию 32) и положить в буфер обмена")
    ap.add_argument("--out", help="куда записать НОВЫЙ SealedSecret, если в репо его ещё нет")
    ap.add_argument("--new-field", action="store_true", help="разрешить добавить поле, которого нет в живом секрете")
    ap.add_argument("--dry-run", action="store_true", help="ничего не менять: показать, какое поле поменялось бы")
    ap.add_argument("--apply", action="store_true", help="после записи сразу применить SealedSecret в кластер")
    ap.add_argument("--no-validate", action="store_true", help="не вызывать kubeseal --validate")
    args = ap.parse_args()

    name, ns = args.secret, args.namespace
    if "/" in name:
        ns, name = name.split("/", 1)

    # 1) где лежит файл в репо
    found = find_sealed(name, ns)
    if len(found) > 1:
        die(f"секрет '{name}' есть в нескольких namespace: {sorted({n for _, n in found})}; укажи -n")
    if found:
        path, ns = found[0]
    else:
        path = None
        if ns is None:
            nss = cluster_namespaces(name)
            if len(nss) != 1:
                die(f"в репо нет SealedSecret '{name}', а в кластере найдено namespace: {nss or 'нет'}; укажи -n")
            ns = nss[0]

    # 2) живой секрет: только имена ключей
    keys = live_keys(ns, name)
    if keys is None:
        print(f"предупреждение: живого секрета {ns}/{name} в кластере нет (ещё не применён?)", file=sys.stderr)
    elif args.field not in keys and not args.new_field:
        die(f"в живом секрете {ns}/{name} нет поля '{args.field}'; есть: {', '.join(keys)} (или --new-field)")

    value = read_value(args)
    if value == "":
        die("пустое значение")

    if path is not None:
        # 3a) замена одного поля в существующем файле
        sealed_doc = yaml.safe_load(path.read_text())
        before = dict(sealed_doc.get("spec", {}).get("encryptedData") or {})
        manifest = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name, "namespace": ns},
                    "stringData": {args.field: value}}
        target = path
        tmpdir = None
        if args.dry_run:
            tmpdir = tempfile.mkdtemp()
            target = Path(tmpdir) / path.name
            shutil.copy(path, target)
        backup = path.read_bytes()
        cmd = kubeseal_base() + ["--scope", scope_of(sealed_doc), "--merge-into", str(target)]
        run(cmd, stdin=json.dumps(manifest).encode())
        after = dict(yaml.safe_load(target.read_text()).get("spec", {}).get("encryptedData") or {})
        changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
        if changed != [args.field]:
            if not args.dry_run:
                path.write_bytes(backup)  # откат: изменилось не только запрошенное поле
            die(f"изменилось не только '{args.field}': {changed}; файл возвращён как был")
        verb = "изменилось бы" if args.dry_run else "изменено"
        print(f"{verb} в {path.relative_to(REPO)}: поле '{args.field}' (остальные шифртексты не тронуты)")
        if args.dry_run:
            shutil.rmtree(tmpdir, ignore_errors=True)
            return
    else:
        # 3b) файла в репо нет: новый SealedSecret из живого секрета с очищенными метаданными
        if not args.out:
            die(f"SealedSecret '{name}' в sealed-secrets/ не найден: укажи --out sealed-secrets/<папка>/{name}-sealed.yaml")
        if keys is None:
            die("для создания нового SealedSecret нужен живой секрет в кластере")
        live = json.loads(run(["kubectl", "-n", ns, "get", "secret", name, "-o", "json"]).stdout)
        meta = live.get("metadata", {})
        clean = {"name": name, "namespace": ns}
        for k in ("labels", "annotations"):
            kept = {a: b for a, b in (meta.get(k) or {}).items() if not a.startswith(SYSTEM_PREFIXES)}
            if kept:
                clean[k] = kept
        data = dict(live.get("data") or {})
        data.pop(args.field, None)
        manifest = {"apiVersion": "v1", "kind": "Secret", "metadata": clean, "type": live.get("type", "Opaque"),
                    "data": data, "stringData": {args.field: value}}
        out = Path(args.out)
        out = out if out.is_absolute() else REPO / out
        if out.exists():
            die(f"{out} уже существует")
        p = run(kubeseal_base() + ["--format", "yaml"], stdin=json.dumps(manifest).encode())
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(p.stdout)
        path = out
        print(f"создан {path.relative_to(REPO)}; не забудь добавить его в kustomization.yaml рядом")
        if args.dry_run:
            path.unlink()
            return

    # 4) проверка и применение
    if not args.no_validate:
        v = run(kubeseal_base() + ["--validate"], stdin=path.read_bytes(), check=False)
        print("kubeseal --validate: " + ("ок, контроллер расшифрует" if v.returncode == 0
                                         else "НЕ прошла: " + v.stderr.decode().strip()[:200]))
    if args.apply:
        run(["kubectl", "apply", "-f", str(path)])
        print("применён в кластер (контроллер обновит Secret; приложение подхватит его через reloader, если он настроен)")
    else:
        print("в кластер не применялось: закоммить и запушь (Flux применит) или повтори с --apply")
    d = subprocess.run(["git", "-C", str(REPO), "diff", "--stat", "--", str(path)], capture_output=True, text=True)
    if d.stdout.strip():
        print(d.stdout.strip())


if __name__ == "__main__":
    main()
