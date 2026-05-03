"""
Export Model Script
===================
Run this ONCE before deploying:
    cd "EDP ML"
    python deployment/export_model.py
"""
import os, sys, json, joblib
import pandas as pd, numpy as np
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import balanced_accuracy_score, f1_score
from sklearn.preprocessing import StandardScaler
import warnings; warnings.filterwarnings('ignore')

try:
    from imblearn.over_sampling import SMOTE
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "imbalanced-learn", "-q"])
    from imblearn.over_sampling import SMOTE

np.random.seed(42)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
DATA_PATH = os.path.join(PROJECT_DIR, "sample_training_data (1).csv")
OUT_DIR = os.path.join(SCRIPT_DIR, "artifacts")
os.makedirs(OUT_DIR, exist_ok=True)

print("=" * 60)
print("  MODEL EXPORT PIPELINE")
print("=" * 60)

# ── Load Data ──
print("\n[1/7] Loading data...")
df = pd.read_csv(DATA_PATH)
print(f"  Shape: {df.shape}")

# ── Synthetic Extension ──
print("[2/7] Creating synthetic machines...")
def clone_machine(src, new_id):
    s = src.copy(); s['machine_id'] = new_id
    for c in ['accel_x','accel_y','accel_z','bpfo_energy','bpfi_energy','bsf_energy','ftf_energy','fault_score','temperature']:
        s[c] += np.random.normal(0, src[c].std()*0.12, len(src))
    for c in ['bpfo_energy','bpfi_energy','bsf_energy','ftf_energy']:
        s[c] = s[c].clip(0.005)
    s['fault_score'] = s['fault_score'].clip(0.015, 0.065)
    s['temperature'] = s['temperature'].clip(25, 40)
    return s

orig_ids = df['machine_id'].unique()
parts = [df]
for i in range(25):
    src = df[df['machine_id'] == orig_ids[i % len(orig_ids)]]
    parts.append(clone_machine(src, 5 + i))
df_all = pd.concat(parts, ignore_index=True)
df_all.sort_values(['machine_id','timestamp'], inplace=True)
df_all.reset_index(drop=True, inplace=True)
print(f"  Machines: {df_all['machine_id'].nunique()}")

# ── Hourly Aggregation ──
print("[3/7] Hourly aggregation...")
hourly_list = []
for mid in df_all['machine_id'].unique():
    md = df_all[df_all['machine_id']==mid].sort_values('timestamp').reset_index(drop=True)
    md['hr'] = md.index // 60
    agg = md.groupby('hr').agg(
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
    agg['machine_id'] = mid; agg = agg.fillna(0)
    hourly_list.append(agg)
hourly = pd.concat(hourly_list, ignore_index=True)
print(f"  Hourly rows: {len(hourly)}")

# ── 5-Day Windows ──
print("[4/7] Building 5-day windows...")
WINDOW, HORIZON, STRIDE = 120, 24, 2
all_ff = []
for mid in hourly['machine_id'].unique():
    md = hourly[hourly['machine_id']==mid].sort_values('hr').reset_index(drop=True)
    for s in range(0, len(md)-WINDOW-HORIZON, STRIDE):
        fut = md.iloc[s+WINDOW:s+WINDOW+HORIZON]
        all_ff.append(fut['lbl2_cnt'].sum()+fut['fault_cnt'].sum())
THRESHOLD = np.median(all_ff)
feat_cols = [c for c in hourly.columns if c not in ['hr','machine_id']]
all_X, all_y = [], []
for mid in hourly['machine_id'].unique():
    md = hourly[hourly['machine_id']==mid].sort_values('hr').reset_index(drop=True)
    for s in range(0, len(md)-WINDOW-HORIZON, STRIDE):
        w = md.iloc[s:s+WINDOW]; f = md.iloc[s+WINDOW:s+WINDOW+HORIZON]
        feats = {}
        for col in feat_cols:
            v = w[col].values.astype(float)
            feats[f'{col}_mean']=np.mean(v); feats[f'{col}_std']=np.std(v)
            feats[f'{col}_max']=np.max(v); feats[f'{col}_min']=np.min(v)
            feats[f'{col}_range']=np.ptp(v)
            feats[f'{col}_trend']=np.polyfit(np.arange(len(v)),v,1)[0] if len(v)>2 else 0.0
        feats['accel_rms']=np.sqrt(np.mean(w['ax_m']**2+w['ay_m']**2+w['az_m']**2))
        feats['total_bearing']=np.mean(w['bpfo_m']+w['bpfi_m']+w['bsf_m']+w['ftf_m'])
        feats['fs_above_mean']=(w['fs_m']>w['fs_m'].mean()).sum()
        target = 1 if (f['lbl2_cnt'].sum()+f['fault_cnt'].sum()) > THRESHOLD else 0
        all_X.append(feats); all_y.append(target)
X_df = pd.DataFrame(all_X).fillna(0).replace([np.inf,-np.inf],0)
y = np.array(all_y)
print(f"  Samples: {len(y)} | Features: {X_df.shape[1]}")

# ── Train/Test + SMOTE ──
print("[5/7] Train/test split + SMOTE...")
X_train,X_test,y_train,y_test = train_test_split(X_df,y,test_size=0.2,random_state=42,stratify=y)
scaler = StandardScaler()
X_tr = scaler.fit_transform(X_train); X_te = scaler.transform(X_test)
min_k = max(1, min(5, min(sum(y_train==0),sum(y_train==1))-1))
X_tr_sm, y_tr_sm = SMOTE(random_state=42,k_neighbors=min_k).fit_resample(X_tr,y_train)

# ── Train & Compare ──
print("[6/7] Training models...")
rf = RandomForestClassifier(n_estimators=300,max_depth=12,min_samples_split=5,min_samples_leaf=2,class_weight='balanced',random_state=42,n_jobs=-1)
rf.fit(X_tr_sm,y_tr_sm)
rf_bacc=balanced_accuracy_score(y_test,rf.predict(X_te))
rf_f1=f1_score(y_test,rf.predict(X_te),zero_division=0)
print(f"  RF  — BalAcc:{rf_bacc:.4f} F1:{rf_f1:.4f}")

gb = GradientBoostingClassifier(n_estimators=300,max_depth=5,learning_rate=0.05,min_samples_split=5,subsample=0.8,random_state=42)
gb.fit(X_tr_sm,y_tr_sm)
gb_bacc=balanced_accuracy_score(y_test,gb.predict(X_te))
gb_f1=f1_score(y_test,gb.predict(X_te),zero_division=0)
print(f"  GB  — BalAcc:{gb_bacc:.4f} F1:{gb_f1:.4f}")

best_model,best_name = (rf,"RandomForest") if rf_bacc>=gb_bacc else (gb,"GradientBoosting")
best_bacc = max(rf_bacc,gb_bacc)
best_f1v = rf_f1 if rf_bacc>=gb_bacc else gb_f1
print(f"\n  * Best: {best_name}")

# ── Save Artifacts ──
print("[7/7] Saving artifacts...")
joblib.dump(best_model, os.path.join(OUT_DIR,"model.pkl"))
joblib.dump(scaler, os.path.join(OUT_DIR,"scaler.pkl"))
config = {
    "model_name":best_name, "balanced_accuracy":round(best_bacc,4),
    "f1_score":round(best_f1v,4), "feature_names":list(X_df.columns),
    "n_features":X_df.shape[1], "hourly_feat_cols":feat_cols,
    "window_hours":WINDOW, "horizon_hours":HORIZON,
    "threshold":float(THRESHOLD), "classes":["LOW_RISK","HIGH_RISK"],
    "training_samples":int(len(y)),
    "training_date":pd.Timestamp.now().isoformat()
}
with open(os.path.join(OUT_DIR,"model_config.json"),'w') as f:
    json.dump(config,f,indent=2)
print(f"  Saved to: {OUT_DIR}")
print("=" * 60)
print("  DONE — now deploy with these artifacts")
print("=" * 60)
