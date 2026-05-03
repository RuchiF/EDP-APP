import pandas as pd
import numpy as np

df = pd.read_csv('sample_training_data (1).csv')
m0 = df[df['machine_id']==0].reset_index(drop=True)
m0['hour'] = m0.index // 60
h = m0.groupby('hour').agg(fc=('label', lambda x: (x==2).sum()))

print('Fault counts per hour stats:')
print(h['fc'].describe())
print()
print('Percentiles:')
for p in [50, 60, 70, 75, 80, 90, 95]:
    val = h['fc'].quantile(p/100)
    print(f'  {p}th: {val:.1f}')
print()
print('Value counts of fault_count per hour:')
print(h['fc'].value_counts().sort_index())
print()
# What about using fault_score as a predictor target?
print('Fault score stats by status:')
for st in ['NORMAL', 'WARNING', 'FAULT']:
    subset = df[df['status'] == st]
    print(f'  {st}: mean={subset["fault_score"].mean():.4f}, max={subset["fault_score"].max():.4f}')
print()
# Check if we should predict HIGH fault score instead
m0['high_fault'] = (m0['fault_score'] > m0['fault_score'].quantile(0.75)).astype(int)
print('High fault score (>75th pct) distribution:')
print(m0['high_fault'].value_counts())
