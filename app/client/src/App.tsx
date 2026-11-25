import { useEffect, useState } from 'react';
import { Badge } from '@databricks/appkit-ui/react';
import { ReviewPage } from './pages/review/ReviewPage';
import { api } from './pages/review/api';

function App() {
  const [officer, setOfficer] = useState<string | null>(null);

  useEffect(() => {
    api.whoami().then((w) => setOfficer(w.officer)).catch(() => setOfficer(null));
  }, []);

  return (
    <div className="min-h-screen bg-background flex flex-col">
      <header className="border-b px-4 md:px-6 py-3 flex flex-wrap items-center gap-3">
        <h1 className="text-lg font-semibold text-foreground">Permit Pack Check</h1>
        <span className="text-sm text-muted-foreground">Trade Division officer review</span>
        <Badge variant="outline">Synthetic demo data</Badge>
        <div className="ml-auto text-xs text-muted-foreground">
          {officer ? <>Signed in as <span className="text-foreground">{officer}</span></> : 'Identity unavailable'}
        </div>
      </header>
      <main className="flex-1 p-4 md:p-6">
        <ReviewPage />
      </main>
    </div>
  );
}

export default App;
