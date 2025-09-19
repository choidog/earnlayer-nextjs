// Quick debug script to test the approval endpoint
const userId = "106569477483889782566";

async function testApproval() {
  try {
    console.log("Testing approval endpoint...");

    const response = await fetch("https://api.earnlayerai.com/api/admin/users/" + userId + "/approval", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // You'll need to replace this with your actual admin session cookie
        "Cookie": "admin-session=your-actual-session-cookie"
      },
      body: JSON.stringify({
        status: "approved",
        reason: "Test approval"
      })
    });

    const result = await response.text();
    console.log("Status:", response.status);
    console.log("Response:", result);

  } catch (error) {
    console.error("Error:", error);
  }
}

testApproval();