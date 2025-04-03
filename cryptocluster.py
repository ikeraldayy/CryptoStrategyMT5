import pandas as pd
import numpy as np
import glob
from sklearn.cluster import MiniBatchKMeans  # ✅ use MiniBatchKMeans
from sklearn.preprocessing import StandardScaler
import matplotlib.pyplot as plt
import seaborn as sns

# Path to folder containing CSV files
path = '/Users/ikeralday/'  # Your folder path

# Load all CSV files
files = glob.glob(path + '*_15m.csv')

# Dictionary to hold DataFrames
data = {}

# Read and store each DataFrame
for file in files:
    symbol = file.split('/')[-1].replace('_15m.csv', '')  # Extract symbol name
    df = pd.read_csv(file, parse_dates=['timestamp'])
    data[symbol] = df
    
# -------------------------------
# Compute log returns
# -------------------------------
returns = {}

for symbol, df in data.items():
    df = df.sort_values('timestamp')  # Ensure time order
    df['log_return'] = np.log(df['close'] / df['close'].shift(1))
    returns[symbol] = df[['timestamp', 'log_return']].set_index('timestamp')

# -------------------------------
# Align all return series on common timestamps
# -------------------------------
returns_df = pd.concat(returns.values(), axis=1, join='inner')
returns_df.columns = returns.keys()  # Set coin names as columns
returns_df.dropna(inplace=True)  # Drop rows with NaN
print(f"Returns dataframe shape: {returns_df.shape}")

# -------------------------------
# Correlation matrix
# -------------------------------
corr_matrix = returns_df.corr()
print("\nCorrelation Matrix:\n", corr_matrix)

# -------------------------------
# Distance matrix for clustering
# -------------------------------
distance_matrix = 1 - corr_matrix  # Convert correlation to distance

# Standardize distance matrix
scaler = StandardScaler()
X = scaler.fit_transform(distance_matrix)

# -------------------------------
# MiniBatchKMeans clustering (much safer on Mac)
# -------------------------------
n_clusters = 3  # Set number of clusters
kmeans = MiniBatchKMeans(n_clusters=n_clusters, random_state=42, n_init=10)  # ✅ MINI BATCH version
labels = kmeans.fit_predict(X)

# -------------------------------
# Cluster assignments
# -------------------------------
cluster_assignments = pd.DataFrame({
    'Coin': corr_matrix.columns,
    'Cluster': labels
}).sort_values('Cluster').reset_index(drop=True)

print("\nCluster Assignments:\n", cluster_assignments)

# -------------------------------
# Optional: Save result
# -------------------------------
cluster_assignments.to_csv(path + 'cluster_assignments.csv', index=False)
print(f"\nCluster assignments saved to: {path}cluster_assignments.csv")

# -------------------------------
# Plot correlation heatmap
# -------------------------------
plt.figure(figsize=(12, 10))
sns.heatmap(corr_matrix, annot=True, cmap='coolwarm', center=0)
plt.title('Correlation Matrix of Log Returns')
plt.show()
