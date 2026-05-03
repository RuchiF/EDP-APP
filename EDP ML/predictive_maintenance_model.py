"""
Predictive Maintenance Model
=============================
Uses 5 days of industrial sensor data to predict future faults.

Target: Will the next 24-hour period have elevated fault activity?
  - "Elevated" = fault count in the future window exceeds the median
  - This gives a meaningful binary split since raw fault labels are
    distributed across all time periods.

Pipeline:
  1. Load original data + generate synthetic machines (extend dataset)
  2. Aggregate to hourly level
  3. Create 5-day sliding window features
  4. Binary target based on fault severity threshold
  5. Balance with SMOTE, train RF + GB classifiers
  6. Print all metrics
"""

import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.model_selection import train_test_split, StratifiedKFold, cross_val_score
from sklearn.metrics import (
    classification_report, confusion_matrix, accuracy_score,
    precision_score, recall_score, f1_score, roc_auc_score,
    roc_curve, average_precision_score, matthews_corrcoef,
    cohen_kappa_score, balanced_accuracy_score, log_loss
)
from sklearn.preprocessing import StandardScaler
import warnings
warnings.filterwarnings('ignore')

try:
    from imblearn.over_sampling import SMOTE
except ImportError:
    import subprocess, sys
    subprocess.check_call([sys.executable, "-m", "pip", "install", "imbalanced-learn", "-q"])
    from imblearn.over_sampling import SMOTE

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    HAS_PLOT = True
except ImportError:
    HAS_PLOT = False

np.random.seed(42)

# ============================================================
# STEP 1: Load Data
# ============================================================
print("=" * 65)
print("  STEP 1: Loading and Exploring Data")
print("=" * 65)

df = pd.read_csv('sample_training_data (1).csv')
print(f"  Shape: {df.shape} | Machines: {df['machine_id'].nunique()}")
print(f"  Interval: 60s | Duration/machine: ~{len(df)//df['machine_id'].nunique()//1440:.0f} days")
print(f"\n  Label distribution:")
for lbl in sorted(df['label'].unique()):
    n = (df['label']==lbl).sum()
    tag = {0:'Normal',1:'Warning',2:'Fault'}.get(lbl, '?')
    print(f"    {lbl} ({tag}): {n} ({n/len(df)*100:.1f}%)")

# ============================================================
# STEP 2: Extend Dataset with Synthetic Machines
# ============================================================
print("\n" + "=" * 65)
print("  STEP 2: Creating Synthetic Machines (data extension)")
print("=" * 65)

def clone_machine(src, new_id):
    s = src.copy()
    s['machine_id'] = new_id
    noise_cols = ['accel_x','accel_y','accel_z','bpfo_energy','bpfi_energy',
                  'bsf_energy','ftf_energy','fault_score','temperature']
    for c in noise_cols:
        s[c] += np.random.normal(0, src[c].std() * 0.12, len(src))
    for c in ['bpfo_energy','bpfi_energy','bsf_energy','ftf_energy']:
        s[c] = s[c].clip(0.005)
    s['fault_score'] = s['fault_score'].clip(0.015, 0.065)
    s['temperature'] = s['temperature'].clip(25, 40)
    return s

orig_ids = df['machine_id'].unique()
parts = [df]
N_SYNTH = 25
for i in range(N_SYNTH):
    src = df[df['machine_id'] == orig_ids[i % len(orig_ids)]]
    parts.append(clone_machine(src, 5 + i))

df_all = pd.concat(parts, ignore_index=True)
df_all.sort_values(['machine_id','timestamp'], inplace=True)
df_all.reset_index(drop=True, inplace=True)

N_MACHINES = df_all['machine_id'].nunique()
print(f"  Total machines: {N_MACHINES} | Total rows: {len(df_all)}")

# ============================================================
# STEP 3: Hourly Aggregation
# ============================================================
print("\n" + "=" * 65)
print("  STEP 3: Hourly Aggregation")
print("=" * 65)

hourly_list = []
for mid in df_all['machine_id'].unique():
    md = df_all[df_all['machine_id'] == mid].sort_values('timestamp').reset_index(drop=True)
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
    agg['machine_id'] = mid
    agg = agg.fillna(0)
    hourly_list.append(agg)

hourly = pd.concat(hourly_list, ignore_index=True)
print(f"  Hourly rows: {len(hourly)} | Per machine: ~{len(hourly)//N_MACHINES}")

# ============================================================
# STEP 4: Build 5-Day Windows with Severity-Based Target
# ============================================================
print("\n" + "=" * 65)
print("  STEP 4: 5-Day Window Features + Severity Target")
print("=" * 65)

WINDOW = 120  # 5 days in hours
HORIZON = 24  # predict next 24 hours
STRIDE = 2

# First pass: compute the global median fault count per HORIZON window
# to set a meaningful threshold
all_future_faults = []
for mid in hourly['machine_id'].unique():
    md = hourly[hourly['machine_id'] == mid].sort_values('hr').reset_index(drop=True)
    for start in range(0, len(md) - WINDOW - HORIZON, STRIDE):
        future = md.iloc[start+WINDOW : start+WINDOW+HORIZON]
        all_future_faults.append(future['lbl2_cnt'].sum() + future['fault_cnt'].sum())

THRESHOLD = np.median(all_future_faults)
print(f"  Future-window fault stats: mean={np.mean(all_future_faults):.1f}, "
      f"median={THRESHOLD:.0f}, max={np.max(all_future_faults):.0f}")
print(f"  Target threshold: fault_events > {THRESHOLD:.0f} => 'HIGH RISK'")

feat_cols = [c for c in hourly.columns if c not in ['hr','machine_id']]
all_X, all_y = [], []

for mid in hourly['machine_id'].unique():
    md = hourly[hourly['machine_id'] == mid].sort_values('hr').reset_index(drop=True)
    for start in range(0, len(md) - WINDOW - HORIZON, STRIDE):
        w = md.iloc[start:start+WINDOW]
        f = md.iloc[start+WINDOW:start+WINDOW+HORIZON]

        feats = {}
        for col in feat_cols:
            v = w[col].values.astype(float)
            feats[f'{col}_mean'] = np.mean(v)
            feats[f'{col}_std'] = np.std(v)
            feats[f'{col}_max'] = np.max(v)
            feats[f'{col}_min'] = np.min(v)
            feats[f'{col}_range'] = np.ptp(v)
            if len(v) > 2:
                feats[f'{col}_trend'] = np.polyfit(np.arange(len(v)), v, 1)[0]
            else:
                feats[f'{col}_trend'] = 0.0

        # Derived features
        feats['accel_rms'] = np.sqrt(np.mean(w['ax_m']**2 + w['ay_m']**2 + w['az_m']**2))
        feats['total_bearing'] = np.mean(w['bpfo_m'] + w['bpfi_m'] + w['bsf_m'] + w['ftf_m'])
        feats['fs_above_mean'] = (w['fs_m'] > w['fs_m'].mean()).sum()

        # Target: elevated fault activity
        future_faults = f['lbl2_cnt'].sum() + f['fault_cnt'].sum()
        target = 1 if future_faults > THRESHOLD else 0

        all_X.append(feats)
        all_y.append(target)

X_df = pd.DataFrame(all_X).fillna(0).replace([np.inf, -np.inf], 0)
y = np.array(all_y)

n0 = (y==0).sum()
n1 = (y==1).sum()
print(f"\n  Total samples: {len(y)} | Features: {X_df.shape[1]}")
print(f"  Target distribution:")
print(f"    Low Risk  (0): {n0} ({n0/len(y)*100:.1f}%)")
print(f"    High Risk (1): {n1} ({n1/len(y)*100:.1f}%)")

# ============================================================
# STEP 5: Train-Test Split & SMOTE
# ============================================================
print("\n" + "=" * 65)
print("  STEP 5: Train-Test Split & SMOTE")
print("=" * 65)

X_train, X_test, y_train, y_test = train_test_split(
    X_df, y, test_size=0.2, random_state=42, stratify=y)

scaler = StandardScaler()
X_tr = scaler.fit_transform(X_train)
X_te = scaler.transform(X_test)

print(f"  Train: {len(y_train)} | Test: {len(y_test)}")
print(f"  Train target: 0={sum(y_train==0)}, 1={sum(y_train==1)}")

min_k = min(5, min(sum(y_train==0), sum(y_train==1)) - 1)
min_k = max(1, min_k)
smote = SMOTE(random_state=42, k_neighbors=min_k)
X_tr_sm, y_tr_sm = smote.fit_resample(X_tr, y_train)
print(f"  After SMOTE: {len(y_tr_sm)} (0={sum(y_tr_sm==0)}, 1={sum(y_tr_sm==1)})")

# ============================================================
# STEP 6: Train Models
# ============================================================
print("\n" + "=" * 65)
print("  STEP 6: Training Models")
print("=" * 65)

rf = RandomForestClassifier(
    n_estimators=300, max_depth=12, min_samples_split=5,
    min_samples_leaf=2, class_weight='balanced', random_state=42, n_jobs=-1)
rf.fit(X_tr_sm, y_tr_sm)
rf_pred = rf.predict(X_te)
rf_prob = rf.predict_proba(X_te)[:, 1]
print("  [1] Random Forest      - trained")

gb = GradientBoostingClassifier(
    n_estimators=300, max_depth=5, learning_rate=0.05,
    min_samples_split=5, subsample=0.8, random_state=42)
gb.fit(X_tr_sm, y_tr_sm)
gb_pred = gb.predict(X_te)
gb_prob = gb.predict_proba(X_te)[:, 1]
print("  [2] Gradient Boosting  - trained")

# ============================================================
# STEP 7: All Metrics
# ============================================================
print("\n" + "=" * 65)
print("  STEP 7: Comprehensive Model Metrics")
print("=" * 65)


def show_metrics(yt, yp, ypr, name):
    print(f"\n{'_'*62}")
    print(f"  {name}")
    print(f"{'_'*62}")

    acc  = accuracy_score(yt, yp)
    bacc = balanced_accuracy_score(yt, yp)
    prec = precision_score(yt, yp, zero_division=0)
    rec  = recall_score(yt, yp, zero_division=0)
    f1v  = f1_score(yt, yp, zero_division=0)
    mcc  = matthews_corrcoef(yt, yp)
    kap  = cohen_kappa_score(yt, yp)
    ll   = log_loss(yt, ypr)

    cm = confusion_matrix(yt, yp)
    tn, fp, fn, tp = cm.ravel()
    spec = tn/(tn+fp) if (tn+fp)>0 else 0
    npv  = tn/(tn+fn) if (tn+fn)>0 else 0

    try:    auc = roc_auc_score(yt, ypr)
    except: auc = None
    try:    ap = average_precision_score(yt, ypr)
    except: ap = None

    rows = [
        ('Accuracy',              f'{acc:.4f}'),
        ('Balanced Accuracy',     f'{bacc:.4f}'),
        ('Precision (PPV)',       f'{prec:.4f}'),
        ('Recall (Sensitivity)',  f'{rec:.4f}'),
        ('Specificity (TNR)',     f'{spec:.4f}'),
        ('F1-Score',              f'{f1v:.4f}'),
        ('MCC',                   f'{mcc:.4f}'),
        ("Cohen's Kappa",         f'{kap:.4f}'),
        ('Log Loss',              f'{ll:.4f}'),
        ('NPV',                   f'{npv:.4f}'),
        ('ROC-AUC',               f'{auc:.4f}' if auc else 'N/A'),
        ('Avg Precision (PR-AUC)',f'{ap:.4f}' if ap else 'N/A'),
    ]

    print(f"\n  +{'='*30}+{'='*12}+")
    print(f"  | {'Metric':<28s} | {'Value':>10s} |")
    print(f"  +{'-'*30}+{'-'*12}+")
    for label, val in rows:
        print(f"  | {label:<28s} | {val:>10s} |")
    print(f"  +{'='*30}+{'='*12}+")

    print(f"\n  Confusion Matrix:")
    print(f"                     Predicted")
    print(f"                   LowRisk  HighRisk")
    print(f"    Actual Low   |  {tn:>5d}    {fp:>5d}")
    print(f"    Actual High  |  {fn:>5d}    {tp:>5d}")

    print(f"\n  Classification Report:")
    rpt = classification_report(yt, yp, target_names=['Low Risk','High Risk'], digits=4)
    for line in rpt.split('\n'):
        print(f"    {line}")

    return dict(accuracy=acc, balanced_acc=bacc, precision=prec,
                recall=rec, f1=f1v, mcc=mcc, kappa=kap, auc=auc,
                ap=ap, specificity=spec)


rf_m = show_metrics(y_test, rf_pred, rf_prob, "RANDOM FOREST")
gb_m = show_metrics(y_test, gb_pred, gb_prob, "GRADIENT BOOSTING")

# ============================================================
# STEP 8: Cross-Validation
# ============================================================
print("\n" + "=" * 65)
print("  STEP 8: 5-Fold Stratified Cross-Validation")
print("=" * 65)

X_all_sc = scaler.fit_transform(X_df)
cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)

for mname, model in [("Random Forest", rf), ("Gradient Boosting", gb)]:
    print(f"\n  {mname}:")
    for sc in ['accuracy','f1','precision','recall','roc_auc']:
        scores = cross_val_score(model, X_all_sc, y, cv=cv, scoring=sc)
        print(f"    {sc:<12s}: {scores.mean():.4f} (+/- {scores.std():.4f})")

# ============================================================
# STEP 9: Feature Importance
# ============================================================
print("\n" + "=" * 65)
print("  STEP 9: Top 15 Feature Importances (RF)")
print("=" * 65)

fi = sorted(zip(X_df.columns, rf.feature_importances_), key=lambda x: -x[1])
print(f"\n  {'#':<4} {'Feature':<40} {'Score':>8}")
print(f"  {'='*4} {'='*40} {'='*8}")
for i,(n,v) in enumerate(fi[:15],1):
    bar = '#' * int(v/fi[0][1]*20)
    print(f"  {i:<4} {n[:40]:<40} {v:>8.5f}  {bar}")

# ============================================================
# STEP 10: Side-by-Side Comparison
# ============================================================
print("\n" + "=" * 65)
print("  STEP 10: Model Comparison")
print("=" * 65)

print(f"\n  +{'='*20}+{'='*14}+{'='*14}+")
print(f"  | {'Metric':<18s} | {'Rand Forest':>12s} | {'Grad Boost':>12s} |")
print(f"  +{'-'*20}+{'-'*14}+{'-'*14}+")
for k in ['accuracy','balanced_acc','precision','recall','specificity','f1','mcc','kappa','auc','ap']:
    rv = rf_m.get(k)
    gv = gb_m.get(k)
    rs = f'{rv:.4f}' if rv is not None else 'N/A'
    gs = f'{gv:.4f}' if gv is not None else 'N/A'
    w1 = '*' if (rv or 0) >= (gv or 0) else ' '
    w2 = '*' if (gv or 0) > (rv or 0) else ' '
    print(f"  | {k.upper():<18s} | {rs:>10s}{w1:>2s} | {gs:>10s}{w2:>2s} |")
print(f"  +{'='*20}+{'='*14}+{'='*14}+")
print(f"  * = better\n")

# ============================================================
# STEP 11: Plots
# ============================================================
if HAS_PLOT:
    print("=" * 65)
    print("  STEP 11: Saving Plots")
    print("=" * 65)

    def plot_cm(ax, cm, title, cmap_name):
        im = ax.imshow(cm, interpolation='nearest', cmap=plt.cm.get_cmap(cmap_name))
        ax.set_title(title)
        ax.set_xticks([0,1]); ax.set_yticks([0,1])
        ax.set_xticklabels(['Low','High']); ax.set_yticklabels(['Low','High'])
        ax.set_xlabel('Predicted'); ax.set_ylabel('Actual')
        for i in range(2):
            for j in range(2):
                ax.text(j, i, str(cm[i,j]), ha='center', va='center',
                        color='white' if cm[i,j] > cm.max()/2 else 'black', fontsize=14)

    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle('Predictive Maintenance - Model Evaluation', fontsize=15, fontweight='bold')

    plot_cm(axes[0,0], confusion_matrix(y_test, rf_pred), 'RF Confusion Matrix', 'Blues')
    plot_cm(axes[0,1], confusion_matrix(y_test, gb_pred), 'GB Confusion Matrix', 'Oranges')

    try:
        fpr1, tpr1, _ = roc_curve(y_test, rf_prob)
        fpr2, tpr2, _ = roc_curve(y_test, gb_prob)
        axes[1,0].plot(fpr1, tpr1, 'b-', lw=2, label=f'RF AUC={rf_m["auc"]:.3f}')
        axes[1,0].plot(fpr2, tpr2, 'r-', lw=2, label=f'GB AUC={gb_m["auc"]:.3f}')
        axes[1,0].plot([0,1],[0,1],'k--',alpha=0.3)
        axes[1,0].set_xlabel('FPR'); axes[1,0].set_ylabel('TPR')
        axes[1,0].set_title('ROC Curves'); axes[1,0].legend(); axes[1,0].grid(alpha=0.3)
    except:
        pass

    top = fi[:10]
    axes[1,1].barh(range(len(top)), [v for _,v in top], color='steelblue')
    axes[1,1].set_yticks(range(len(top)))
    axes[1,1].set_yticklabels([n[:25] for n,_ in top], fontsize=7)
    axes[1,1].invert_yaxis()
    axes[1,1].set_title('Top 10 Features (RF)')
    axes[1,1].grid(alpha=0.3, axis='x')

    plt.tight_layout()
    plt.savefig('model_evaluation_plots.png', dpi=150, bbox_inches='tight')
    print("  Saved: model_evaluation_plots.png")

print("\n" + "=" * 65)
print("  DONE")
print("=" * 65)
print(f"  Original: {df.shape[0]} rows, {df['machine_id'].nunique()} machines")
print(f"  Extended: {N_MACHINES} machines via synthetic cloning")
print(f"  Window: 5 days -> predict fault severity in next {HORIZON}h")
print(f"  Samples: {len(y)} | Features: {X_df.shape[1]}")
print(f"  Models: Random Forest, Gradient Boosting")
print("=" * 65)
