"""
Bearing Fault Prediction API
=============================
FastAPI service that loads a trained ML model, fetches live sensor
data from Google Firestore, and returns risk predictions.

Endpoints:
  GET  /              → health check
  GET  /model/info    → model metadata
  GET  /predict?machine_id=X  → prediction for machine X
  POST /predict       → prediction (JSON body: {"machine_id": "X"})
"""

import os, json, base64, tempfile, logging, traceback
from datetime import datetime, timezone
from contextlib import asynccontextmanager

import joblib
import numpy as np
import pandas as pd
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional

# ── Logging ──────────────────────────────────────────────────────
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("predictor")

# ── Globals (loaded at startup) ──────────────────────────────────
model = None
scaler = None
config = None
db = None

# ── Paths ────────────────────────────────────────────────────────
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ARTIFACTS_DIR = os.path.join(BASE_DIR, "artifacts")

# ── Firebase Init ────────────────────────────────────────────────
def init_firestore():
    """Initialize Firestore client from env var or local JSON file."""
    global db
    import firebase_admin
    from firebase_admin import credentials, firestore

    if firebase_admin._apps:
        db = firestore.client()
        return

    # Option 1: Base64-encoded credentials in env var
    cred_b64 = os.environ.get("FIREBASE_CREDENTIALS")
    if cred_b64:
        cred_json = base64.b64decode(cred_b64).decode("utf-8")
        cred_dict = json.loads(cred_json)
        cred = credentials.Certificate(cred_dict)
        firebase_admin.initialize_app(cred)
        db = firestore.client()
        logger.info("Firestore initialized from env var")
        return

    # Option 2: Local JSON file (for development)
    local_json = os.path.join(
        os.path.dirname(BASE_DIR),
        "thermo-vibro-monitor-firebase-adminsdk-fbsvc-a38c326deb.json"
    )
    if os.path.exists(local_json):
        cred = credentials.Certificate(local_json)
        firebase_admin.initialize_app(cred)
        db = firestore.client()
        logger.info(f"Firestore initialized from local file")
        return

    logger.warning("No Firebase credentials found — /predict will fail")


# ── Lifespan ─────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load model artifacts and Firebase on startup."""
    global model, scaler, config

    # Load model
    model_path = os.path.join(ARTIFACTS_DIR, "model.pkl")
    scaler_path = os.path.join(ARTIFACTS_DIR, "scaler.pkl")
    config_path = os.path.join(ARTIFACTS_DIR, "model_config.json")

    if os.path.exists(model_path):
        model = joblib.load(model_path)
        logger.info(f"Model loaded: {model_path}")
    else:
        logger.error(f"Model not found at {model_path}")

    if os.path.exists(scaler_path):
        scaler = joblib.load(scaler_path)
        logger.info("Scaler loaded")

    if os.path.exists(config_path):
        with open(config_path) as f:
            config = json.load(f)
        logger.info(f"Config loaded: {config['model_name']}")

    # Init Firestore
    try:
        init_firestore()
    except Exception as e:
        logger.error(f"Firebase init failed: {e}")

    yield  # App runs here

    logger.info("Shutting down")


# ── App ──────────────────────────────────────────────────────────
app = FastAPI(
    title="Bearing Fault Prediction API",
    description="Predicts bearing fault risk from live Firestore sensor data",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(Exception)
async def global_exception_handler(request, exc):
    """Return detailed error info instead of generic 500."""
    tb = traceback.format_exc()
    logger.error(f"Unhandled error: {exc}\n{tb}")
    return JSONResponse(
        status_code=500,
        content={"detail": str(exc), "traceback": tb},
    )


# ── Request / Response Schemas ───────────────────────────────────
class PredictRequest(BaseModel):
    machine_id: Optional[str] = None

class PredictResponse(BaseModel):
    prediction: str
    confidence: float
    probabilities: dict
    window_hours_used: int
    raw_readings_fetched: int
    timestamp: str


# ── Preprocessing Functions ──────────────────────────────────────
def fetch_sensor_data(machine_id: Optional[str] = None, limit: int = 7200):
    """Fetch latest raw sensor readings from Firestore 'data' collection."""
    try:
        if db is None:
            raise HTTPException(503, "Firestore not connected")

        from google.cloud.firestore_v1 import query as fquery
        collection_ref = db.collection("data")
        query = collection_ref.order_by(
            "timestamp",
            direction=fquery.Query.DESCENDING,
        ).limit(limit)

        docs = query.stream()
        records = []
        for doc in docs:
            d = doc.to_dict()
            status = d.get("status", "NORMAL")
            if status == "FAULT":
                d["label"] = 2
            elif status == "WARNING":
                d["label"] = 1
            else:
                d["label"] = 0
            d["temp_alert"] = int(d.get("temp_alert", False))
            d["vibration"] = int(d.get("vibration", False))
            records.append(d)

        if not records:
            raise HTTPException(404, "No sensor data found in Firestore")

        df = pd.DataFrame(records)
        df = df.sort_values("timestamp").reset_index(drop=True)
        return df, False  # is_fallback = False

    except Exception as e:
        if "Quota" in str(e) or "429" in str(e) or getattr(e, "code", None) == 429:
            logger.warning(f"Firestore quota exceeded ({e}). Using local fallback data.")
            # Fallback to local CSV
            csv_path = os.path.join(os.path.dirname(BASE_DIR), "sample_training_data (1).csv")
            if not os.path.exists(csv_path):
                raise HTTPException(500, "Firestore quota exceeded and no fallback data found.")
            
            df = pd.read_csv(csv_path)
            # Ensure bools are ints
            if "temp_alert" in df.columns:
                df["temp_alert"] = df["temp_alert"].astype(int)
            if "vibration" in df.columns:
                df["vibration"] = df["vibration"].astype(int)
            
            # Take the last `limit` rows to simulate fetching the latest data
            df = df.tail(limit).reset_index(drop=True)
            return df, True  # is_fallback = True
        
        # Re-raise if it's not a quota error
        raise e


def hourly_aggregate(df: pd.DataFrame) -> pd.DataFrame:
    """Aggregate raw minute-level data into hourly bins (groups of 60)."""
    df = df.copy()
    df['hr'] = df.index // 60

    agg = df.groupby('hr').agg(
        ax_m=('accel_x','mean'), ax_s=('accel_x','std'),
        ax_max=('accel_x','max'), ax_min=('accel_x','min'),
        ay_m=('accel_y','mean'), ay_s=('accel_y','std'),
        ay_max=('accel_y','max'), ay_min=('accel_y','min'),
        az_m=('accel_z','mean'), az_s=('accel_z','std'),
        az_max=('accel_z','max'), az_min=('accel_z','min'),
        bpfo_m=('bpfo_energy','mean'), bpfo_mx=('bpfo_energy','max'),
        bpfi_m=('bpfi_energy','mean'), bpfi_mx=('bpfi_energy','max'),
        bsf_m=('bsf_energy','mean'), bsf_mx=('bsf_energy','max'),
        ftf_m=('ftf_energy','mean'), ftf_mx=('ftf_energy','max'),
        fs_m=('fault_score','mean'), fs_s=('fault_score','std'),
        fs_mx=('fault_score','max'), fs_mn=('fault_score','min'),
        t_m=('temperature','mean'), t_mx=('temperature','max'),
        ta_cnt=('temp_alert','sum'), vib_cnt=('vibration','sum'),
        warn_cnt=('status', lambda x: (x=='WARNING').sum()),
        fault_cnt=('status', lambda x: (x=='FAULT').sum()),
        lbl2_cnt=('label', lambda x: (x==2).sum()),
        lbl1_cnt=('label', lambda x: (x==1).sum()),
        bl_m=('baseline_mean','mean'), bl_s=('baseline_std','mean'),
        wt_m=('warn_threshold','mean'), ft_m=('fault_threshold','mean'),
    ).reset_index()

    return agg.fillna(0)


def extract_window_features(hourly_df: pd.DataFrame, window: int = 120) -> pd.DataFrame:
    """Extract the same statistical features used during training."""
    feat_cols = config["hourly_feat_cols"]

    # Use the last `window` hourly rows
    if len(hourly_df) < window:
        # Pad by repeating the earliest row
        pad_n = window - len(hourly_df)
        pad_df = pd.concat([hourly_df.iloc[[0]]]*pad_n, ignore_index=True)
        hourly_df = pd.concat([pad_df, hourly_df], ignore_index=True)
        logger.warning(f"Padded {pad_n} hours to reach window={window}")

    w = hourly_df.tail(window).reset_index(drop=True)

    feats = {}
    for col in feat_cols:
        if col not in w.columns:
            v = np.zeros(window)
        else:
            v = w[col].values.astype(float)
        feats[f'{col}_mean'] = np.mean(v)
        feats[f'{col}_std'] = np.std(v)
        feats[f'{col}_max'] = np.max(v)
        feats[f'{col}_min'] = np.min(v)
        feats[f'{col}_range'] = np.ptp(v)
        feats[f'{col}_trend'] = np.polyfit(np.arange(len(v)), v, 1)[0] if len(v) > 2 else 0.0

    feats['accel_rms'] = float(np.sqrt(np.mean(w['ax_m']**2 + w['ay_m']**2 + w['az_m']**2)))
    feats['total_bearing'] = float(np.mean(w['bpfo_m'] + w['bpfi_m'] + w['bsf_m'] + w['ftf_m']))
    feats['fs_above_mean'] = int((w['fs_m'] > w['fs_m'].mean()).sum())

    # Build DataFrame with exact feature order
    feature_names = config["feature_names"]
    row = {fn: feats.get(fn, 0.0) for fn in feature_names}
    X = pd.DataFrame([row])[feature_names]
    X = X.fillna(0).replace([np.inf, -np.inf], 0)
    return X


# ── Endpoints ────────────────────────────────────────────────────
@app.get("/", tags=["Health"])
def health_check():
    return {
        "status": "healthy",
        "model_loaded": model is not None,
        "firestore_connected": db is not None,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }


@app.get("/model/info", tags=["Model"])
def model_info():
    if config is None:
        raise HTTPException(503, "Model config not loaded")
    return {
        "model_name": config["model_name"],
        "balanced_accuracy": config["balanced_accuracy"],
        "f1_score": config["f1_score"],
        "n_features": config["n_features"],
        "window_hours": config["window_hours"],
        "classes": config["classes"],
        "training_date": config.get("training_date"),
    }


@app.get("/predict", tags=["Prediction"])
def predict_get(machine_id: Optional[str] = Query(None)):
    return run_prediction(machine_id)


@app.post("/predict", tags=["Prediction"], response_model=PredictResponse)
def predict_post(req: PredictRequest):
    return run_prediction(req.machine_id)


def run_prediction(machine_id: Optional[str] = None) -> dict:
    """Core prediction pipeline."""
    if model is None or scaler is None or config is None:
        raise HTTPException(503, "Model not loaded. Run export_model.py first.")

    # 1. Fetch raw data
    window = config["window_hours"]
    needed_readings = window * 60  # 1-minute intervals
    raw_df, is_fallback = fetch_sensor_data(machine_id, limit=needed_readings)
    n_raw = len(raw_df)
    logger.info(f"Fetched {n_raw} raw readings (fallback: {is_fallback})")

    # 2. Hourly aggregation
    hourly_df = hourly_aggregate(raw_df)
    logger.info(f"Hourly rows: {len(hourly_df)}")

    # 3. Extract window features
    X = extract_window_features(hourly_df, window)

    # 4. Scale
    X_scaled = scaler.transform(X)

    # 5. Predict
    pred = model.predict(X_scaled)[0]
    proba = model.predict_proba(X_scaled)[0]
    class_label = config["classes"][int(pred)]  # "LOW_RISK" or "HIGH_RISK"
    confidence = float(np.max(proba))
    
    timestamp_str = datetime.now(timezone.utc).isoformat()
    if is_fallback:
        timestamp_str += " (Quota Exceeded: Using Local Data)"

    return PredictResponse(
        prediction=class_label,
        confidence=round(confidence, 4),
        probabilities={
            "LOW_RISK": round(float(proba[0]), 4),
            "HIGH_RISK": round(float(proba[1]), 4),
        },
        window_hours_used=window,
        raw_readings_fetched=n_raw,
        timestamp=timestamp_str,
    )


# ── Main ─────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8000))
    uvicorn.run("app:app", host="0.0.0.0", port=port, reload=True)
