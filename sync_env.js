const { execSync } = require('child_process');
const fs = require('fs');
try {
    const output = execSync('npx supabase status -o json', { encoding: 'utf8' });
    const status = JSON.parse(output);
    const envContent = `NEXT_PUBLIC_SUPABASE_URL="${status.API_URL}"\nNEXT_PUBLIC_SUPABASE_ANON_KEY="${status.ANON_KEY}"\nRESEND_API_KEY="re_EoH3131R_PJmZsYCGeE7zyN3fBgEHQhe2"\n`;
    fs.writeFileSync('.env.local', envContent);
    console.log('.env.local updated successfully.');
    console.log('ANON_KEY identified:', status.ANON_KEY.substring(0, 10) + '...');
} catch (e) {
    console.error('Error:', e.message);
}
