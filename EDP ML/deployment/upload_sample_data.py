"""
Upload minimal sample data to Firestore for API testing.
Uploads just 120 readings (~2 hours) — the API will pad the rest.
"""
import os, json, time
import pandas as pd
import google.auth.transport.requests
from google.oauth2 import service_account

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
CSV_PATH = os.path.join(PROJECT_DIR, "sample_training_data (1).csv")
CRED_PATH = os.path.join(
    PROJECT_DIR,
    "thermo-vibro-monitor-firebase-adminsdk-fbsvc-a38c326deb.json"
)

with open(CRED_PATH) as f:
    cred_data = json.load(f)
PROJECT_ID = cred_data["project_id"]

scopes = ["https://www.googleapis.com/auth/datastore"]
creds = service_account.Credentials.from_service_account_file(CRED_PATH, scopes=scopes)
session = google.auth.transport.requests.AuthorizedSession(creds)
BASE_URL = f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents"

# Only 120 readings — enough for 2 hourly bins, rest will be padded
N_READINGS = 120
df = pd.read_csv(CSV_PATH)
data = df[df['machine_id'] == 0].head(N_READINGS).reset_index(drop=True)
print(f"Uploading {len(data)} readings to Firestore...")

uploaded = 0
for i in range(len(data)):
    row = data.iloc[i]
    body = {"fields": {
        "accel_x": {"doubleValue": float(row["accel_x"])},
        "accel_y": {"doubleValue": float(row["accel_y"])},
        "accel_z": {"doubleValue": float(row["accel_z"])},
        "bpfo_energy": {"doubleValue": float(row["bpfo_energy"])},
        "bpfi_energy": {"doubleValue": float(row["bpfi_energy"])},
        "bsf_energy": {"doubleValue": float(row["bsf_energy"])},
        "ftf_energy": {"doubleValue": float(row["ftf_energy"])},
        "fault_score": {"doubleValue": float(row["fault_score"])},
        "baseline_mean": {"doubleValue": float(row["baseline_mean"])},
        "baseline_std": {"doubleValue": float(row["baseline_std"])},
        "warn_threshold": {"doubleValue": float(row["warn_threshold"])},
        "fault_threshold": {"doubleValue": float(row["fault_threshold"])},
        "temperature": {"doubleValue": float(row["temperature"])},
        "temp_alert": {"booleanValue": bool(row["temp_alert"])},
        "vibration": {"booleanValue": bool(row["vibration"])},
        "status": {"stringValue": str(row["status"])},
        "timestamp": {"integerValue": str(int(row["timestamp"]))},
        "calibrated": {"booleanValue": True},
    }}
    for attempt in range(3):
        try:
            resp = session.post(f"{BASE_URL}/data", json=body, timeout=15)
            if resp.status_code in (200, 201):
                uploaded += 1
                break
            else:
                print(f"  [{i}] HTTP {resp.status_code}: {resp.text[:80]}")
                time.sleep(1)
        except Exception as e:
            print(f"  [{i}] Error: {e}")
            time.sleep(2)
    if uploaded % 20 == 0 and uploaded > 0:
        print(f"  {uploaded}/{len(data)} uploaded")

print(f"\nDone! {uploaded}/{len(data)} documents uploaded.")
