#!/bin/bash

# TEK Application Approval Helper
# Usage: ./approve.sh <appId> [approve|reject]

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <appId> [approve|reject]"
    echo "Example: $0 8xK9mPqW2vN4jLrT5sY approve"
    echo ""
    echo "Or run without arguments to see pending applications:"
    echo "  $0 list"
    exit 1
fi

if [ "$1" == "list" ]; then
    echo "Fetching pending applications..."
    cd cloud_functions
    node approve-cli.js
    exit 0
fi

APP_ID=$1
ACTION=${2:-approve}

if [ "$ACTION" != "approve" ] && [ "$ACTION" != "reject" ]; then
    echo "Error: Action must be 'approve' or 'reject'"
    exit 1
fi

echo "Processing application..."
echo "App ID: $APP_ID"
echo "Action: $ACTION"
echo ""

cd cloud_functions

# Use Firebase CLI to call the function
firebase functions:shell <<EOF
approveApplication({appId: '$APP_ID', action: '$ACTION'})
EOF

echo ""
echo "Done! Check Firebase Console for confirmation."
