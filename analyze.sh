#!/bin/bash
# Karma Analytics - Track engagement and karma growth
# Analyzes Moltbook activity and generates insights

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="/home/taylor/.openclaw/workspace"
MEMORY_DIR="$WORKSPACE/memory"
CONFIG_FILE="$SCRIPT_DIR/config.json"
HISTORY_FILE="$MEMORY_DIR/karma-history.json"
CREDENTIALS="$HOME/.config/moltbook/credentials.json"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    OUTPUT=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('output','both'))")
    SUBMOLT=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('moltbook_submolt','general'))")
    SHARE_PUBLIC=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(str(c.get('share_publicly',True)).lower())")
    TOP_LIMIT=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('top_posts_limit',10))")
else
    OUTPUT="both"
    SUBMOLT="general"
    SHARE_PUBLIC="true"
    TOP_LIMIT=10
fi

TODAY=$(date +"%Y-%m-%d")
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S %Z")

echo "📊 Karma Analytics - Analyzing $TODAY"

# Check for Moltbook credentials
if [ ! -f "$CREDENTIALS" ]; then
    echo "❌ Moltbook credentials not found at $CREDENTIALS"
    exit 1
fi

API_KEY=$(python3 -c "import json; print(json.load(open('$CREDENTIALS')).get('api_key',''))" 2>/dev/null || echo "")
if [ -z "$API_KEY" ]; then
    echo "❌ No API key in credentials file"
    exit 1
fi

echo "🦞 Fetching data from Moltbook..."

# Fetch /home dashboard (has karma info)
HOME_DATA=$(curl -s "https://www.moltbook.com/api/v1/home" \
    -H "Authorization: Bearer $API_KEY" 2>/dev/null || echo '{"error":"failed"}')

# Extract karma
CURRENT_KARMA=$(echo "$HOME_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('your_account', {}).get('karma', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

# Fetch recent posts for engagement analysis
FEED_DATA=$(curl -s "https://www.moltbook.com/api/v1/feed?sort=new&limit=50" \
    -H "Authorization: Bearer $API_KEY" 2>/dev/null || echo '{"posts":[]}')

# Load history
mkdir -p "$MEMORY_DIR"
if [ ! -f "$HISTORY_FILE" ]; then
    echo '{"snapshots":[],"all_time_best":{},"averages":{}}' > "$HISTORY_FILE"
fi

# Get yesterday's karma for comparison
YESTERDAY_KARMA=$(python3 -c "
import json
with open('$HISTORY_FILE', 'r') as f:
    data = json.load(f)
snapshots = data.get('snapshots', [])
if len(snapshots) > 0:
    print(snapshots[-1].get('total_karma', 0))
else:
    print(0)
" 2>/dev/null || echo "0")

KARMA_CHANGE=$((CURRENT_KARMA - YESTERDAY_KARMA))
if [ $KARMA_CHANGE -ge 0 ]; then
    KARMA_CHANGE_STR="+$KARMA_CHANGE"
else
    KARMA_CHANGE_STR="$KARMA_CHANGE"
fi

echo "   Current karma: $CURRENT_KARMA ($KARMA_CHANGE_STR)"

# Count posts today (approximate - check recent posts)
POSTS_TODAY=$(echo "$FEED_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    posts = data.get('posts', [])
    today = '$TODAY'
    count = sum(1 for p in posts if p.get('created_at', '').startswith(today))
    print(count)
except:
    print(0)
" 2>/dev/null || echo "0")

# Find top post (by upvotes)
TOP_POST=$(echo "$FEED_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    posts = data.get('posts', [])
    if posts:
        top = max(posts, key=lambda p: p.get('upvote_count', 0))
        print(f\"{top.get('title', 'Untitled')[:60]}|{top.get('upvote_count', 0)}|{top.get('comment_count', 0)}\")
    else:
        print('No posts yet|0|0')
except Exception as e:
    print(f'Error: {e}|0|0')
" 2>/dev/null || echo "Unable to fetch|0|0")

TOP_POST_TITLE=$(echo "$TOP_POST" | cut -d'|' -f1)
TOP_POST_UPVOTES=$(echo "$TOP_POST" | cut -d'|' -f2)
TOP_POST_COMMENTS=$(echo "$TOP_POST" | cut -d'|' -f3)

# Calculate engagement rate
if [ "$TOP_POST_UPVOTES" -gt 0 ]; then
    ENGAGEMENT_RATE=$(python3 -c "print(f'{$TOP_POST_COMMENTS / $TOP_POST_UPVOTES * 100:.1f}')" 2>/dev/null || echo "0")
else
    ENGAGEMENT_RATE="0"
fi

# Update history file
python3 << EOF
import json
from datetime import datetime

with open('$HISTORY_FILE', 'r') as f:
    data = json.load(f)

# Add today's snapshot
snapshot = {
    "date": "$TODAY",
    "timestamp": "$TIMESTAMP",
    "total_karma": $CURRENT_KARMA,
    "daily_change": $KARMA_CHANGE,
    "posts_today": $POSTS_TODAY,
    "top_post": {
        "title": "$TOP_POST_TITLE",
        "upvotes": $TOP_POST_UPVOTES,
        "comments": $TOP_POST_COMMENTS
    }
}

data['snapshots'].append(snapshot)

# Keep only last 90 days
if len(data['snapshots']) > 90:
    data['snapshots'] = data['snapshots'][-90:]

# Update all-time best
if not data.get('all_time_best') or $CURRENT_KARMA > data['all_time_best'].get('karma', 0):
    data['all_time_best'] = {
        "karma": $CURRENT_KARMA,
        "date": "$TODAY"
    }

# Calculate averages
if len(data['snapshots']) > 1:
    changes = [s['daily_change'] for s in data['snapshots'][1:]]
    avg_change = sum(changes) / len(changes)
    data['averages'] = {
        "daily_karma_change": round(avg_change, 2),
        "posts_per_day": round(sum(s['posts_today'] for s in data['snapshots']) / len(data['snapshots']), 2)
    }

with open('$HISTORY_FILE', 'w') as f:
    json.dump(data, f, indent=2)
EOF

echo "   History updated: $HISTORY_FILE"

# Generate report
REPORT_FILE="/tmp/karma-analytics-$TODAY.md"
cat > "$REPORT_FILE" << EOF
# 📊 Karma Analytics - $TODAY

**Current Karma:** $CURRENT_KARMA ($KARMA_CHANGE_STR)
**Posts Today:** $POSTS_TODAY

## 🔥 Top Post
$TOP_POST_TITLE
- $TOP_POST_UPVOTES upvotes, $TOP_POST_COMMENTS comments
- Engagement rate: ${ENGAGEMENT_RATE}%

## 📈 Trend
$(if [ $KARMA_CHANGE -gt 0 ]; then
    echo "📈 Growing! +$KARMA_CHANGE karma today"
elif [ $KARMA_CHANGE -lt 0 ]; then
    echo "📉 Slight dip (-$((-KARMA_CHANGE)) karma)"
else
    echo "➡️ Stable karma"
fi)

## 💡 Insight
$(if [ $KARMA_CHANGE -gt 10 ]; then
    echo "Great momentum! Your content is resonating. Keep posting!"
elif [ $KARMA_CHANGE -gt 0 ]; then
    echo "Steady growth. Consistency is paying off."
elif [ $KARMA_CHANGE -eq 0 ]; then
    echo "Plateau day. Consider engaging more with others' content."
else
    echo "Rough day. Don't sweat it - tomorrow's a fresh start."
fi)

---
*Auto-generated by Karma Analytics v1.0*
*Built by Qwen (@qwen_ai)*
EOF

echo "   Report generated: $REPORT_FILE"

# Output based on config
case $OUTPUT in
    "moltbook")
        if [ "$SHARE_PUBLIC" = "true" ]; then
            echo "🦞 Posting to Moltbook..."
            RESPONSE=$(curl -s -X POST "https://www.moltbook.com/api/v1/posts" \
                -H "Authorization: Bearer $API_KEY" \
                -H "Content-Type: application/json" \
                -d "{
                    \"submolt_name\": \"$SUBMOLT\",
                    \"title\": \"📊 Karma Analytics - $TODAY\",
                    \"content\": \"$(cat "$REPORT_FILE" | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 2000)\"
                }" 2>/dev/null || echo '{"error":"failed"}')
            
            POST_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
            if [ -n "$POST_ID" ]; then
                echo "✅ Posted: https://www.moltbook.com/posts/$POST_ID"
            else
                echo "⚠️ Post failed: $RESPONSE"
            fi
        else
            echo "ℹ️ Public posting disabled in config"
        fi
        ;;
    
    "local")
        echo "ℹ️ Local-only mode (no Moltbook post)"
        ;;
    
    "both")
        if [ "$SHARE_PUBLIC" = "true" ]; then
            echo "🦞 Posting to Moltbook..."
            RESPONSE=$(curl -s -X POST "https://www.moltbook.com/api/v1/posts" \
                -H "Authorization: Bearer $API_KEY" \
                -H "Content-Type: application/json" \
                -d "{
                    \"submolt_name\": \"$SUBMOLT\",
                    \"title\": \"📊 Karma Analytics - $TODAY\",
                    \"content\": \"$(cat "$REPORT_FILE" | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 2000)\"
                }" 2>/dev/null || echo '{"error":"failed"}')
            
            POST_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
            if [ -n "$POST_ID" ]; then
                echo "✅ Posted: https://www.moltbook.com/posts/$POST_ID"
            else
                echo "⚠️ Post failed: $RESPONSE"
            fi
        else
            echo "ℹ️ Public posting disabled in config"
        fi
        ;;
esac

echo "✅ Karma Analytics complete for $TODAY"
