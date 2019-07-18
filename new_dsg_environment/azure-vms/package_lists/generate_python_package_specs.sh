#!/usr/bin/env bash

# Insert package addition instructions
echo "  # To add additional packages update package_lists/python<python version>-packages.list"

# Initialise temporary files for list operations
CONDA_PKGS_27_SORTED=$(mktemp)
CONDA_PKGS_36_SORTED=$(mktemp)
CONDA_PKGS_37_SORTED=$(mktemp)
NON_CONDA_PKGS_27_SORTED=$(mktemp)
NON_CONDA_PKGS_36_SORTED=$(mktemp)
NON_CONDA_PKGS_37_SORTED=$(mktemp)
CONDA_PKGS_COMMON=$(mktemp)

# Sort the non-conda lists
sort python27-not-installable-with-conda.list > $NON_CONDA_PKGS_27_SORTED
sort python36-not-installable-with-conda.list > $NON_CONDA_PKGS_36_SORTED
sort python37-not-installable-with-conda.list > $NON_CONDA_PKGS_37_SORTED

# Construct combined lists using:
#   1. include requested packages
#   2. include any packages from the utility list
#   3. remove any packages from the sorted non-conda list (these will be installed with pip)
cat python27-packages.list | sort | uniq | comm -23 - $NON_CONDA_PKGS_27_SORTED > $CONDA_PKGS_27_SORTED
cat python36-packages.list | sort | uniq | comm -23 - $NON_CONDA_PKGS_36_SORTED > $CONDA_PKGS_36_SORTED
cat python37-packages.list | sort | uniq | comm -23 - $NON_CONDA_PKGS_37_SORTED > $CONDA_PKGS_37_SORTED

# Create a combined list
comm -12 $CONDA_PKGS_27_SORTED $CONDA_PKGS_36_SORTED | comm -12 - $CONDA_PKGS_37_SORTED > $CONDA_PKGS_COMMON

# Construct minimal common and environment specific lists
echo "  - export PYTHON_CONDA_COMMON=\"$(cat $CONDA_PKGS_COMMON | tr '\n' ' ' | xargs)\""
echo "  - export PYTHON27_CONDA_ADDITIONAL=\"$(comm -23 $CONDA_PKGS_27_SORTED $CONDA_PKGS_COMMON | tr '\n' ' ' | xargs)\""
echo "  - export PYTHON36_CONDA_ADDITIONAL=\"$(comm -23 $CONDA_PKGS_36_SORTED $CONDA_PKGS_COMMON | tr '\n' ' ' | xargs)\""
echo "  - export PYTHON37_CONDA_ADDITIONAL=\"$(comm -23 $CONDA_PKGS_37_SORTED $CONDA_PKGS_COMMON | tr '\n' ' ' | xargs)\""

# Use lists to construct appropriate environment variables
echo "  # Consolidate package lists for each Python version"
echo "  - export PYTHON27_CONDA_PACKAGES=\"\$PYTHON_CONDA_COMMON \$PYTHON27_CONDA_ADDITIONAL\""
echo "  - export PYTHON36_CONDA_PACKAGES=\"\$PYTHON_CONDA_COMMON \$PYTHON36_CONDA_ADDITIONAL\""
echo "  - export PYTHON37_CONDA_PACKAGES=\"\$PYTHON_CONDA_COMMON \$PYTHON37_CONDA_ADDITIONAL\""

# Construct packages that must be installed with pip
echo "  # Construct lists of packages only available through pip for each Python version"
echo "  - export PYTHON27_PIP_PACKAGES=\"$(cat $NON_CONDA_PKGS_27_SORTED | tr '\n' ' ' | xargs)\""
echo "  - export PYTHON36_PIP_PACKAGES=\"$(cat $NON_CONDA_PKGS_36_SORTED | tr '\n' ' ' | xargs)\""
echo "  - export PYTHON37_PIP_PACKAGES=\"$(cat $NON_CONDA_PKGS_37_SORTED | tr '\n' ' ' | xargs)\""

# Insert block footer
echo "  # === AUTOGENERATED ANACONDA PACKAGES END HERE ==="

rm $CONDA_PKGS_27_SORTED $CONDA_PKGS_36_SORTED $CONDA_PKGS_37_SORTED $NON_CONDA_PKGS_27_SORTED $NON_CONDA_PKGS_36_SORTED $NON_CONDA_PKGS_37_SORTED $CONDA_PKGS_COMMON

