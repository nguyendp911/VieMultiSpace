#!/usr/bin/env python3
"""
Giả lập "người dùng thứ hai" để test Trao đổi reaction khi chỉ có 1 điện thoại.

Script này đăng nhập ẩn danh vào Supabase như một người dùng khác điện thoại của bạn,
rồi tạo / nhận / hoàn tất yêu cầu. Nó KHÔNG đụng tới Facebook, chỉ gọi các hàm RPC.

Cách dùng (chạy trên máy tính, cần Python 3):

  # A) Điện thoại ĐÃ tạo yêu cầu -> script nhận nó (tạo cặp ngay).
  #    Thêm --new-user để giả lập thêm một người nhận KHÁC (một yêu cầu nhận được nhiều người).
  python simulate_partner.py --url https://xxxx.supabase.co --key ANON_KEY \
      accept --post-url https://www.facebook.com/<user>/posts/<id> --post-id <id> --reaction LOVE

  # B) Script tạo yêu cầu mở -> điện thoại mở tab Yêu cầu và bấm "Nhận yêu cầu"
  python simulate_partner.py --url ... --key ... \
      create --post-url https://www.facebook.com/<user>/posts/<id> --post-id <id> --reaction LIKE

  # C) Giả vờ đối tác đã thả reaction lên bài của điện thoại (để điện thoại thấy "Hoàn tất")
  python simulate_partner.py --url ... --key ... complete

  # Xem trạng thái các yêu cầu của người dùng giả lập
  python simulate_partner.py --url ... --key ... status

Lưu ý: bài viết của "đối tác" nên là một bài Facebook THẬT (ví dụ bài thứ hai của bạn),
vì điện thoại sẽ thả reaction thật lên bài đó.
Phiên đăng nhập giả lập được lưu ở ~/.exchange_sim_partner.json (xóa file để đổi sang người dùng mới).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

SESSION_FILE = os.path.join(os.path.expanduser("~"), ".exchange_sim_partner.json")


def http(method, url, key, token=None, body=None):
    headers = {"apikey": key, "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body if body is not None else {}).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            msg = json.loads(raw).get("message") or json.loads(raw).get("msg") or raw
        except Exception:
            msg = raw
        sys.exit("Lỗi HTTP %s: %s" % (e.code, msg))


def get_token(base, key):
    if os.path.exists(SESSION_FILE):
        try:
            saved = json.load(open(SESSION_FILE))
            if saved.get("base") == base:
                refreshed = http("POST", base + "/auth/v1/token?grant_type=refresh_token", key,
                                 body={"refresh_token": saved["refresh_token"]})
                if refreshed and refreshed.get("access_token"):
                    save(base, refreshed)
                    return refreshed["access_token"]
        except SystemExit:
            pass
        except Exception:
            pass
    fresh = http("POST", base + "/auth/v1/signup", key, body={})
    save(base, fresh)
    print("Đã tạo người dùng giả lập mới.")
    return fresh["access_token"]


def save(base, sess):
    json.dump({"base": base, "refresh_token": sess.get("refresh_token", "")}, open(SESSION_FILE, "w"))


def rpc(base, key, token, name, params=None):
    return http("POST", base + "/rest/v1/rpc/" + name, key, token, params or {})


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--name", default="Người test")
    p.add_argument("--new-user", action="store_true", help="Bỏ phiên cũ, tạo người dùng giả lập mới")
    sub = p.add_subparsers(dest="cmd", required=True)
    for cmd in ("create", "accept"):
        s = sub.add_parser(cmd)
        s.add_argument("--post-url", required=True)
        s.add_argument("--post-id", required=True)
        s.add_argument("--reaction", default="LIKE")
    sub.add_parser("complete")
    sub.add_parser("status")
    a = p.parse_args()

    base = a.url.rstrip("/")
    if a.new_user and os.path.exists(SESSION_FILE):
        os.remove(SESSION_FILE)
    token = get_token(base, a.key)

    if a.cmd == "create":
        r = rpc(base, a.key, token, "create_exchange_request", {
            "p_post_url": a.post_url, "p_post_id": a.post_id,
            "p_reaction": a.reaction.upper(), "p_display_name": a.name})
        print("Đã tạo yêu cầu chờ:", r["id"])
        print("-> Trên điện thoại: Trao đổi reaction > tab Yêu cầu > Nhận yêu cầu.")

    elif a.cmd == "accept":
        open_reqs = rpc(base, a.key, token, "list_open_requests")
        if not open_reqs:
            sys.exit("Chưa có yêu cầu nào đang mở (hoặc người test đã nhận hết). Hãy tạo yêu cầu trên điện thoại trước.")
        target = open_reqs[0]
        print("Nhận yêu cầu của '%s' (cần nhận %s, đã có %s người nhận)" % (
            target["display_name"], target["reaction"], target["accepted_count"]))
        pair_id = rpc(base, a.key, token, "accept_exchange_request", {
            "p_target_id": target["id"], "p_post_url": a.post_url, "p_post_id": a.post_id,
            "p_reaction": a.reaction.upper(), "p_display_name": a.name})
        print("Đã tạo cặp:", pair_id)
        print("-> Điện thoại sẽ tự thả %s lên bài %s khi mở app (hoặc bấm 'Thả ngay')." % (a.reaction.upper(), a.post_url))

    elif a.cmd == "complete":
        done = 0
        for m in rpc(base, a.key, token, "get_my_pairs"):
            if m["status"] == "matched" and m["my_task_status"] == "pending":
                rpc(base, a.key, token, "report_exchange_task",
                    {"p_pair_id": m["id"], "p_success": True, "p_message": "Giả lập đã thả"})
                done += 1
        print("Đã báo hoàn tất %d lệnh của người test." % done)

    else:
        for r in rpc(base, a.key, token, "get_my_requests"):
            print("yêu cầu %s  status=%-9s đã nhận=%s" % (r["id"][:8], r["status"], r["accepted_count"]))
        for m in rpc(base, a.key, token, "get_my_pairs"):
            print("cặp     %s  %-9s status=%-8s my_task=%-8s partner_task=%s" % (
                m["id"][:8], m["role"], m["status"], m["my_task_status"], m["partner_task_status"]))


if __name__ == "__main__":
    main()
